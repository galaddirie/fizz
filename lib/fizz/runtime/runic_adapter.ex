defmodule Fizz.Runtime.RunicAdapter do
  @moduledoc """
  Bridges Fizz workflow definitions (Steps/Connections) with the Runic execution engine.
  """

  require Runic
  alias Runic.Component
  alias Runic.Workflow
  alias Runic.Workflow.FanOut
  alias Fizz.Runtime.ExecutionContext
  alias Fizz.Runtime.Hooks.Observability
  alias Fizz.Runtime.Steps.StepRunner

  @type source :: Fizz.Workflows.WorkflowDraft.t() | map()
  @type build_opts :: [
          execution_id: String.t(),
          variables: map(),
          metadata: map(),
          step_outputs: map(),
          trigger_data: map(),
          trigger_type: atom()
        ]

  @spec to_runic_workflow(source(), build_opts()) :: Workflow.t()
  def to_runic_workflow(source, opts \\ []) do
    step_outputs = Keyword.get(opts, :step_outputs, %{})
    steps = source.steps || []
    connections = source.connections || []
    groups = Map.get(source, :groups) || []

    group_lookup = build_group_lookup(groups)
    group_by_id = Map.new(groups, &{&1.id, &1})

    {outer_steps, outer_connections} =
      build_outer_graph(steps, connections, group_lookup, group_by_id)

    graph = Fizz.Graph.from_workflow!(outer_steps, outer_connections, validate: false)
    upstream_lookup = build_upstream_lookup(graph)

    # Build step map for looking up step data by ID
    step_map = Map.new(outer_steps, &{&1.id, &1})

    step_opts = [
      execution_id: Keyword.get(opts, :execution_id),
      workflow_id: extract_source_id(source),
      variables: Keyword.get(opts, :variables, %{}),
      metadata: Keyword.get(opts, :metadata, %{}),
      step_outputs: step_outputs,
      upstream_lookup: upstream_lookup,
      trigger_data: Keyword.get(opts, :trigger_data, %{}),
      trigger_type: Keyword.get(opts, :trigger_type),
      all_groups: groups
    ]

    wrk = Workflow.new(name: "execution_#{extract_source_id(source)}")
    parent_lookup = build_parent_lookup(outer_connections)
    sorted_steps = topological_sort_steps(outer_steps, outer_connections)

    # Build splitter lookup to detect fan-out paths
    splitter_ids =
      outer_steps
      |> Enum.filter(&(&1.type_id == "splitter"))
      |> Enum.map(& &1.id)
      |> MapSet.new()

    # Build fan-out path lookup: step_id => fan_out_step_id (which splitter it's downstream of)
    fan_out_path_lookup = build_fan_out_path_lookup(graph, splitter_ids, step_map)

    step_opts =
      step_opts
      |> Keyword.put(:splitter_ids, splitter_ids)
      |> Keyword.put(:fan_out_path_lookup, fan_out_path_lookup)

    wrk =
      Enum.reduce(sorted_steps, wrk, fn step, acc ->
        if step.type_id == "node_group" do
          group = Map.fetch!(group_by_id, step.id)
          add_group_to_workflow(group, steps, connections, acc, parent_lookup, step_opts)
        else
          add_step_to_workflow(step, acc, parent_lookup, step_opts)
        end
      end)

    wrk
    |> put_step_metadata(outer_steps, groups)
    |> track_all_fan_out_paths()
  end

  @spec create_component(Fizz.Workflows.Embeds.Step.t(), String.t(), build_opts()) :: term()
  def create_component(step, component_name, opts \\ []) do
    case step.type_id do
      "splitter" ->
        create_splitter(step, component_name, opts)

      "aggregator" ->
        # Default to join-style aggregator; fan-out aggregator created in add_step_to_workflow
        create_join_aggregator(step, component_name)

      "join" ->
        create_explicit_join(step, component_name, opts)

      "condition" ->
        create_condition(step, component_name, opts)

      "switch" ->
        create_switch(step, component_name, opts)

      _ ->
        StepRunner.create(step, opts)
    end
  end

  # ===========================================================================
  # Group Helpers
  # ===========================================================================

  defp build_group_lookup(groups) do
    groups
    |> Enum.flat_map(fn group -> Enum.map(group.step_ids || [], &{&1, group}) end)
    |> Map.new()
  end

  defp build_outer_graph(steps, connections, group_lookup, group_by_id) do
    ungrouped_steps = Enum.reject(steps, &Map.has_key?(group_lookup, &1.id))

    group_steps =
      group_by_id
      |> Map.values()
      |> Enum.map(&group_step_from_group/1)

    outer_steps = ungrouped_steps ++ group_steps
    outer_connections = build_outer_connections(connections, group_lookup)

    {outer_steps, outer_connections}
  end

  defp group_step_from_group(group) do
    %Fizz.Workflows.Embeds.Step{
      id: group.id,
      type_id: "node_group",
      name: group.name || group.id,
      config: %{},
      position: Map.get(group, :position) || %{},
      notes: nil
    }
  end

  defp build_outer_connections(connections, group_lookup) do
    connections
    |> Enum.reduce([], fn conn, acc ->
      source_id = connection_field(conn, :source_step_id)
      target_id = connection_field(conn, :target_step_id)
      source_group = Map.get(group_lookup, source_id)
      target_group = Map.get(group_lookup, target_id)

      cond do
        source_group && target_group && source_group.id == target_group.id ->
          acc

        true ->
          new_source = if source_group, do: source_group.id, else: source_id
          new_target = if target_group, do: target_group.id, else: target_id

          updated =
            conn
            |> update_connection(%{source_step_id: new_source, target_step_id: new_target})

          [updated | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq_by(&connection_identity/1)
  end

  defp connection_identity(conn) do
    {
      connection_field(conn, :source_step_id),
      connection_field(conn, :target_step_id),
      connection_field(conn, :source_output),
      connection_field(conn, :target_input)
    }
  end

  defp connection_field(conn, key) when is_map(conn) do
    Map.get(conn, key) || Map.get(conn, Atom.to_string(key))
  end

  defp update_connection(conn, attrs) when is_map(conn) do
    if Map.has_key?(conn, :__struct__) do
      struct(conn, attrs)
    else
      Map.merge(conn, attrs)
    end
  end

  # ===========================================================================
  # Fan-out Path Lookup
  # ===========================================================================

  # Build a map of step_id => fan_out_step_id for all steps downstream of a splitter
  defp build_fan_out_path_lookup(graph, splitter_ids, step_map) do
    Enum.reduce(splitter_ids, %{}, fn splitter_id, acc ->
      downstream_ids = find_downstream_until_aggregator(graph, splitter_id, step_map)

      Enum.reduce(downstream_ids, acc, fn step_id, inner_acc ->
        # If a step is downstream of multiple splitters, keep the nearest one
        # For now, just use the first one found
        Map.put_new(inner_acc, step_id, splitter_id)
      end)
    end)
  end

  defp find_downstream_until_aggregator(graph, start_id, step_map) do
    do_find_downstream(graph, [start_id], MapSet.new(), MapSet.new(), step_map)
  end

  defp do_find_downstream(_graph, [], _visited, acc, _step_map), do: MapSet.to_list(acc)

  defp do_find_downstream(graph, [current | rest], visited, acc, step_map) do
    if MapSet.member?(visited, current) do
      do_find_downstream(graph, rest, visited, acc, step_map)
    else
      visited = MapSet.put(visited, current)

      # Get step info to check if it's an aggregator
      is_aggregator =
        case Map.get(step_map, current) do
          %{type_id: "aggregator"} -> true
          _ -> false
        end

      if is_aggregator do
        # Don't traverse past aggregators, but do include them
        do_find_downstream(graph, rest, visited, MapSet.put(acc, current), step_map)
      else
        # Add current to accumulator and continue traversal
        acc = MapSet.put(acc, current)
        children = Fizz.Graph.children(graph, current)
        do_find_downstream(graph, children ++ rest, visited, acc, step_map)
      end
    end
  end

  # ===========================================================================
  # Public helpers for aggregation (called from closures via __MODULE__)
  # ===========================================================================

  @doc false
  def normalize_aggregator_input(nil), do: []

  def normalize_aggregator_input(input) when is_list(input) do
    input
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  def normalize_aggregator_input(input), do: [input]

  @doc false
  def apply_aggregation("sum", items) do
    items
    |> Enum.map(&to_number/1)
    |> Enum.sum()
  end

  def apply_aggregation("count", items), do: length(items)

  def apply_aggregation("concat", items) do
    Enum.map_join(items, "", &to_string/1)
  end

  def apply_aggregation("first", []), do: nil
  def apply_aggregation("first", items), do: List.first(items)

  def apply_aggregation("last", []), do: nil
  def apply_aggregation("last", items), do: List.last(items)

  def apply_aggregation("min", []), do: nil
  def apply_aggregation("min", items), do: Enum.min(items)

  def apply_aggregation("max", []), do: nil
  def apply_aggregation("max", items), do: Enum.max(items)

  # Default "collect" - return flattened list
  def apply_aggregation(_, items), do: items

  @doc false
  def to_number(n) when is_number(n), do: n

  def to_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0
    end
  end

  def to_number(_), do: 0

  # Normalize an item that might be a single value or a list (from a Join)
  @doc false
  def normalize_item(nil), do: []

  def normalize_item(item) when is_list(item) do
    item |> List.flatten() |> Enum.reject(&is_nil/1)
  end

  def normalize_item(item), do: [item]

  # ===========================================================================
  # Private: Workflow Building
  # ===========================================================================

  defp add_group_to_workflow(group, steps, connections, workflow, parent_lookup, step_opts) do
    group_step_ids = MapSet.new(group.step_ids || [])

    group_steps =
      Enum.filter(steps, fn step ->
        MapSet.member?(group_step_ids, step.id)
      end)

    group_connections =
      Enum.filter(connections, fn conn ->
        source_id = connection_field(conn, :source_step_id)
        target_id = connection_field(conn, :target_step_id)

        MapSet.member?(group_step_ids, source_id) and
          MapSet.member?(group_step_ids, target_id)
      end)

    group_component =
      build_group_component(group, group_steps, group_connections, step_opts)

    group_parents = Map.get(parent_lookup, group.id, [])
    connect_component(workflow, group_component, group_parents, step_opts)
  end

  defp build_group_component(group, group_steps, group_connections, step_opts) do
    runic_step =
      Runic.step(
        fn input ->
          execute_group(group, group_steps, group_connections, input, step_opts)
        end,
        name: group.id
      )

    unique_hash = :erlang.phash2({runic_step.hash, group.id}, 4_294_967_296)
    %{runic_step | hash: unique_hash}
  end

  defp execute_group(group, group_steps, group_connections, input, parent_opts) do
    outer_outputs = Process.get(:fizz_accumulated_outputs, %{})
    outer_step_outputs = Process.get(:fizz_step_outputs, %{})
    outer_step_skipped = Process.get(:fizz_step_skipped)
    outer_fan_out_context = Process.get(:fizz_fan_out_context)

    Process.put(:fizz_accumulated_outputs, %{})
    Process.put(:fizz_step_outputs, %{})
    Process.delete(:fizz_step_skipped)
    Process.delete(:fizz_fan_out_context)

    pinned_outputs = Keyword.get(parent_opts, :step_outputs, %{})
    group_step_ids = MapSet.new(group.step_ids || [])

    group_pinned_outputs =
      pinned_outputs
      |> Enum.filter(fn {step_id, _output} -> MapSet.member?(group_step_ids, step_id) end)
      |> Map.new()

    group_opts =
      parent_opts
      |> Keyword.put(:step_outputs, group_pinned_outputs)
      |> Keyword.put(:trigger_data, input)
      |> Keyword.put(:current_group, group)

    group_workflow =
      build_group_workflow(group, group_steps, group_connections, group_opts)
      |> Observability.attach_all_hooks(
        execution_id: Keyword.get(parent_opts, :execution_id),
        workflow_id: Keyword.get(parent_opts, :workflow_id),
        skip_production_init: true
      )

    result_workflow = Workflow.react_until_satisfied(group_workflow, input)
    output = extract_group_output(result_workflow, group.output_step_id)

    updated_outputs = Map.put(outer_outputs, group.id, output)
    Process.put(:fizz_accumulated_outputs, updated_outputs)
    Process.put(:fizz_step_outputs, outer_step_outputs)

    if is_nil(outer_step_skipped) do
      Process.delete(:fizz_step_skipped)
    else
      Process.put(:fizz_step_skipped, outer_step_skipped)
    end

    if is_nil(outer_fan_out_context) do
      Process.delete(:fizz_fan_out_context)
    else
      Process.put(:fizz_fan_out_context, outer_fan_out_context)
    end

    output
  end

  defp build_group_workflow(group, steps, connections, opts) do
    graph = Fizz.Graph.from_workflow!(steps, connections, validate: false)
    upstream_lookup = build_upstream_lookup(graph)
    step_map = Map.new(steps, &{&1.id, &1})

    step_opts =
      opts
      |> Keyword.put(:upstream_lookup, upstream_lookup)
      |> Keyword.put(:all_groups, [])

    wrk = Workflow.new(name: "group_#{group.id}")
    parent_lookup = build_parent_lookup(connections)
    sorted_steps = topological_sort_steps(steps, connections)

    splitter_ids =
      steps
      |> Enum.filter(&(&1.type_id == "splitter"))
      |> Enum.map(& &1.id)
      |> MapSet.new()

    fan_out_path_lookup = build_fan_out_path_lookup(graph, splitter_ids, step_map)

    step_opts =
      step_opts
      |> Keyword.put(:splitter_ids, splitter_ids)
      |> Keyword.put(:fan_out_path_lookup, fan_out_path_lookup)

    wrk =
      Enum.reduce(sorted_steps, wrk, fn step, acc ->
        add_step_to_workflow(step, acc, parent_lookup, step_opts)
      end)

    wrk
    |> put_step_metadata(steps)
    |> track_all_fan_out_paths()
  end

  defp extract_group_output(workflow, output_step_id) do
    ctx = ExecutionContext.from_runic_workflow(workflow)
    ExecutionContext.get_output(ctx, output_step_id)
  end

  defp add_step_to_workflow(step, workflow, parent_lookup, step_opts) do
    component_name = step.id

    parent_ids =
      parent_lookup
      |> Map.get(step.id, [])
      |> Enum.uniq()

    # Determine if this aggregator should use fan-out or join semantics
    component =
      case fetch_pinned_output(step_opts, step.id) do
        {:ok, pinned_output} ->
          create_pinned_component(step, pinned_output)

        :error ->
          if step.type_id == "aggregator" do
            splitter_ids = Keyword.get(step_opts, :splitter_ids, MapSet.new())
            upstream_lookup = Keyword.get(step_opts, :upstream_lookup, %{})
            upstream_ids = Map.get(upstream_lookup, step.id, [])

            # Check if there's a splitter anywhere upstream
            has_upstream_splitter = Enum.any?(upstream_ids, &MapSet.member?(splitter_ids, &1))

            if has_upstream_splitter do
              # Fan-out context: use Runic.reduce to accumulate ALL items
              create_fanout_aggregator(step, component_name)
            else
              # No fan-out upstream: use regular step that handles list input from join
              create_join_aggregator(step, component_name)
            end
          else
            create_component(step, component_name, step_opts)
          end
      end

    workflow = connect_component(workflow, component, parent_ids, step_opts)
    maybe_connect_fan_in(workflow, component)
  end

  defp connect_component(workflow, component, [], _step_opts) do
    Workflow.add(workflow, component)
  end

  defp connect_component(workflow, component, [parent_id], _step_opts) do
    Workflow.add(workflow, component, to: parent_id)
  end

  defp connect_component(workflow, component, parent_ids, step_opts) do
    fan_out_path_lookup = Keyword.get(step_opts, :fan_out_path_lookup, %{})

    {workflow, join} = ensure_join(workflow, parent_ids, fan_out_path_lookup)
    Workflow.add(workflow, component, to: join)
  end

  defp maybe_connect_fan_in(workflow, %Runic.Workflow.Reduce{fan_in: fan_in}) do
    case find_upstream_fan_out(workflow, fan_in) do
      nil ->
        workflow

      fan_out ->
        workflow
        |> Workflow.draw_connection(fan_out, fan_in, :fan_in)
        |> track_mapped_path(fan_out, fan_in)
    end
  end

  defp maybe_connect_fan_in(workflow, _component), do: workflow

  defp fetch_pinned_output(step_opts, step_id) do
    pinned_outputs = Keyword.get(step_opts, :step_outputs, %{})

    if Map.has_key?(pinned_outputs, step_id) do
      {:ok, Map.get(pinned_outputs, step_id)}
    else
      :error
    end
  end

  defp create_pinned_component(step, output) do
    runic_step = Runic.step(fn _input -> output end, name: step.id)
    unique_hash = :erlang.phash2({runic_step.hash, step.id}, 4_294_967_296)
    %{runic_step | hash: unique_hash}
  end

  defp track_mapped_path(workflow, fan_out, fan_in) do
    path = workflow.graph |> Graph.get_shortest_path(fan_out, fan_in)

    path_hashes =
      Enum.reduce(path || [], MapSet.new(), fn node, mapset ->
        case node do
          %{hash: hash} -> MapSet.put(mapset, hash)
          _ -> mapset
        end
      end)

    %Workflow{
      workflow
      | mapped:
          Map.put(
            workflow.mapped,
            :mapped_paths,
            MapSet.union(workflow.mapped[:mapped_paths] || MapSet.new(), path_hashes)
          )
    }
  end

  defp find_upstream_fan_out(workflow, fan_in) do
    do_find_upstream_fan_out(workflow.graph, [fan_in], MapSet.new())
  end

  defp do_find_upstream_fan_out(_graph, [], _visited), do: nil

  defp do_find_upstream_fan_out(graph, [current | rest], visited) do
    if MapSet.member?(visited, current) do
      do_find_upstream_fan_out(graph, rest, visited)
    else
      visited = MapSet.put(visited, current)

      case current do
        %FanOut{} ->
          current

        _ ->
          predecessors =
            graph
            |> Graph.in_edges(current)
            |> Enum.filter(&(&1.label == :flow))
            |> Enum.map(& &1.v1)

          do_find_upstream_fan_out(graph, predecessors ++ rest, visited)
      end
    end
  end

  # ===========================================================================
  # Fan-out Path Tracking (for observability - item_index/items_total)
  # ===========================================================================

  @doc false
  defp track_all_fan_out_paths(workflow) do
    fan_outs =
      workflow.graph
      |> Graph.vertices()
      |> Enum.filter(&match?(%FanOut{}, &1))

    Enum.reduce(fan_outs, workflow, fn fan_out, wf ->
      downstream_hashes = find_all_downstream_hashes(wf.graph, fan_out)

      existing_paths = wf.mapped[:mapped_paths] || MapSet.new()
      new_paths = MapSet.union(existing_paths, downstream_hashes)

      %Workflow{wf | mapped: Map.put(wf.mapped, :mapped_paths, new_paths)}
    end)
  end

  @doc false
  defp find_all_downstream_hashes(graph, start_node) do
    do_find_downstream_hashes(graph, [start_node], MapSet.new(), MapSet.new())
  end

  defp do_find_downstream_hashes(_graph, [], _visited, acc), do: acc

  defp do_find_downstream_hashes(graph, [current | rest], visited, acc) do
    if MapSet.member?(visited, current) do
      do_find_downstream_hashes(graph, rest, visited, acc)
    else
      visited = MapSet.put(visited, current)

      acc =
        case current do
          %{hash: hash} when not is_nil(hash) ->
            MapSet.put(acc, hash)

          _ ->
            acc
        end

      successors =
        case current do
          %Runic.Workflow.FanIn{} ->
            []

          %Runic.Workflow.Reduce{} ->
            []

          _ ->
            graph
            |> Graph.out_edges(current)
            |> Enum.filter(&(&1.label == :flow))
            |> Enum.map(& &1.v2)
        end

      do_find_downstream_hashes(graph, successors ++ rest, visited, acc)
    end
  end

  # ===========================================================================
  # Join Creation
  # ===========================================================================

  defp ensure_join(%Workflow{} = workflow, parent_ids, fan_out_path_lookup)
       when is_list(parent_ids) do
    parent_steps = Enum.map(parent_ids, &Workflow.get_component!(workflow, &1))
    parent_hashes = Enum.map(parent_steps, &Component.hash/1)

    # Build fan_out_sources map for fan-out aware joining
    fan_out_sources =
      parent_ids
      |> Enum.zip(parent_hashes)
      |> Enum.reduce(%{}, fn {parent_id, parent_hash}, acc ->
        case Map.get(fan_out_path_lookup, parent_id) do
          nil ->
            acc

          fan_out_id ->
            # Get the hash of the fan-out component
            case Workflow.get_component(workflow, fan_out_id) do
              nil ->
                acc

              fan_out_component ->
                Map.put(acc, parent_hash, Component.hash(fan_out_component))
            end
        end
      end)

    # Determine if this is a fan-out aware join
    join =
      if map_size(fan_out_sources) > 0 do
        Workflow.Join.new(parent_hashes,
          fan_out_sources: fan_out_sources,
          mode: :zip_nil
        )
      else
        Workflow.Join.new(parent_hashes)
      end

    case Map.get(workflow.graph.vertices, join.hash) do
      %Workflow.Join{} = existing_join -> {workflow, existing_join}
      nil -> {Workflow.add_step(workflow, parent_steps, join), join}
    end
  end

  defp extract_source_id(source) do
    Map.get(source, :id) || Map.get(source, :workflow_id) || "unknown"
  end

  defp build_parent_lookup(connections) do
    Enum.group_by(connections, & &1.target_step_id, & &1.source_step_id)
  end

  defp build_upstream_lookup(graph) do
    Enum.reduce(Fizz.Graph.vertex_ids(graph), %{}, fn step_id, acc ->
      Map.put(acc, step_id, Fizz.Graph.upstream(graph, step_id))
    end)
  end

  defp topological_sort_steps(steps, connections) do
    step_ids = Enum.map(steps, & &1.id)
    step_map = Map.new(steps, &{&1.id, &1})

    in_degrees = Map.new(step_ids, &{&1, 0})

    in_degrees =
      Enum.reduce(connections, in_degrees, fn conn, acc ->
        Map.update(acc, conn.target_step_id, 0, &(&1 + 1))
      end)

    adjacency =
      Enum.reduce(connections, %{}, fn conn, acc ->
        Map.update(acc, conn.source_step_id, [conn.target_step_id], &[conn.target_step_id | &1])
      end)

    roots = Enum.filter(step_ids, &(Map.get(in_degrees, &1) == 0))
    sorted_ids = do_kahn_sort(roots, in_degrees, adjacency, [])
    Enum.map(sorted_ids, &Map.get(step_map, &1))
  end

  defp do_kahn_sort([], _in_degrees, _adjacency, sorted), do: Enum.reverse(sorted)

  defp do_kahn_sort([id | rest], in_degrees, adjacency, sorted) do
    children = Map.get(adjacency, id, [])

    {new_rest, new_in_degrees} =
      Enum.reduce(children, {rest, in_degrees}, fn child, {r, degs} ->
        new_deg = Map.get(degs, child) - 1
        degs = Map.put(degs, child, new_deg)
        if new_deg == 0, do: {r ++ [child], degs}, else: {r, degs}
      end)

    do_kahn_sort(new_rest, new_in_degrees, adjacency, [id | sorted])
  end

  defp put_step_metadata(workflow, steps, groups \\ [])

  defp put_step_metadata(workflow, steps, groups) when is_list(steps) do
    step_metadata =
      Enum.reduce(steps, %{}, fn step, acc ->
        Map.put(acc, step.id, %{
          type_id: step.type_id,
          step_id: step.id,
          name: step.name
        })
      end)

    step_metadata =
      Enum.reduce(groups, step_metadata, fn group, acc ->
        Map.put(acc, group.id, %{
          type_id: "node_group",
          step_id: group.id,
          name: group.name || group.id,
          skip_observability: true
        })
      end)

    Map.put(workflow, :__step_metadata__, step_metadata)
  end

  defp put_step_metadata(workflow, _steps, _groups), do: workflow

  # ===========================================================================
  # Private: Component Creation
  # ===========================================================================

  defp create_splitter(step, component_name, opts) do
    work_fn = fn input ->
      result = StepRunner.execute_with_context(step, input, opts)
      # The FanOut invokable sets item_index and items_total on each Fact
      # No need for global process state tracking
      result
    end

    %FanOut{
      name: component_name,
      work: work_fn,
      hash: :erlang.phash2({:fan_out, step.id}, 4_294_967_296)
    }
  end

  # Fan-out aggregator: uses Runic.reduce for proper FanIn/FanOut semantics
  defp create_fanout_aggregator(step, component_name) do
    operation = Map.get(step.config, "operation", "collect")
    name = component_name
    step_id = step.id

    reduce =
      case operation do
        "sum" ->
          Runic.reduce(
            0,
            fn item, acc ->
              items = __MODULE__.normalize_item(item)
              Enum.reduce(items, acc, fn i, a -> a + (__MODULE__.to_number(i) || 0) end)
            end,
            name: name
          )

        "count" ->
          Runic.reduce(
            0,
            fn item, acc ->
              items = __MODULE__.normalize_item(item)
              acc + length(items)
            end,
            name: name
          )

        "concat" ->
          Runic.reduce(
            "",
            fn item, acc ->
              items = __MODULE__.normalize_item(item)
              acc <> Enum.map_join(items, "", &to_string/1)
            end,
            name: name
          )

        "first" ->
          Runic.reduce(
            nil,
            fn
              item, nil ->
                items = __MODULE__.normalize_item(item)
                List.first(items)

              _item, acc ->
                acc
            end,
            name: name
          )

        "last" ->
          Runic.reduce(
            nil,
            fn item, _acc ->
              items = __MODULE__.normalize_item(item)
              List.last(items) || List.first(items)
            end,
            name: name
          )

        "min" ->
          Runic.reduce(
            nil,
            fn item, acc ->
              items = __MODULE__.normalize_item(item)
              item_min = Enum.min(items, fn -> nil end)

              case {acc, item_min} do
                {nil, val} -> val
                {val, nil} -> val
                {a, b} -> min(a, b)
              end
            end,
            name: name
          )

        "max" ->
          Runic.reduce(
            nil,
            fn item, acc ->
              items = __MODULE__.normalize_item(item)
              item_max = Enum.max(items, fn -> nil end)

              case {acc, item_max} do
                {nil, val} -> val
                {val, nil} -> val
                {a, b} -> max(a, b)
              end
            end,
            name: name
          )

        # Default "collect" - accumulate all items into a flat list
        _ ->
          Runic.reduce(
            [],
            fn item, acc ->
              items = __MODULE__.normalize_item(item)
              acc ++ items
            end,
            name: name
          )
      end

    unique_hash = :erlang.phash2({reduce.hash, step_id}, 4_294_967_296)
    unique_fan_in = %{reduce.fan_in | hash: unique_hash}
    %{reduce | hash: unique_hash, fan_in: unique_fan_in}
  end

  # Join aggregator: handles pre-combined list input from Join nodes (no fan-out upstream)
  defp create_join_aggregator(step, component_name) do
    operation = Map.get(step.config, "operation", "collect")
    step_id = step.id

    runic_step =
      Runic.step(
        fn input ->
          items = __MODULE__.normalize_aggregator_input(input)
          __MODULE__.apply_aggregation(operation, items)
        end,
        name: component_name
      )

    unique_hash = :erlang.phash2({runic_step.hash, step_id}, 4_294_967_296)
    %{runic_step | hash: unique_hash}
  end

  # Explicit join step: user-configurable join behavior
  defp create_explicit_join(step, component_name, _opts) do
    mode = Map.get(step.config, "mode", "zip_nil")
    flatten? = Map.get(step.config, "flatten", false)

    runic_step =
      Runic.step(
        fn input ->
          result = apply_join_mode(mode, input)

          if flatten? do
            List.flatten(result)
          else
            result
          end
        end,
        name: component_name
      )

    unique_hash = :erlang.phash2({runic_step.hash, step.id}, 4_294_967_296)
    %{runic_step | hash: unique_hash}
  end

  defp apply_join_mode("wait_all", input) when is_list(input) do
    List.flatten(input, [])
  end

  defp apply_join_mode("zip_nil", input) when is_list(input) do
    Runic.Workflow.Join.apply_mode(:zip_nil, normalize_branch_input(input))
  end

  defp apply_join_mode("zip_shortest", input) when is_list(input) do
    Runic.Workflow.Join.apply_mode(:zip_shortest, normalize_branch_input(input))
  end

  defp apply_join_mode("zip_cycle", input) when is_list(input) do
    Runic.Workflow.Join.apply_mode(:zip_cycle, normalize_branch_input(input))
  end

  defp apply_join_mode("cartesian", input) when is_list(input) do
    Runic.Workflow.Join.apply_mode(:cartesian, normalize_branch_input(input))
  end

  defp apply_join_mode(_mode, input), do: input

  defp normalize_branch_input(input) when is_list(input) do
    if Enum.all?(input, &is_list/1) do
      input
    else
      [input]
    end
  end

  defp create_condition(step, component_name, opts) do
    condition_expr = Map.get(step.config, "condition", "true")

    Runic.rule(
      name: component_name,
      if: fn input -> evaluate_condition(condition_expr, input, opts) end,
      do: fn input -> input end
    )
  end

  defp create_switch(step, _component_name, opts) do
    StepRunner.create(step, opts)
  end

  defp evaluate_condition(expr, input, opts) when is_binary(expr) do
    vars = %{
      "json" => input,
      "variables" => Keyword.get(opts, :variables, %{})
    }

    case Fizz.Runtime.Expression.evaluate_with_vars(expr, vars) do
      {:ok, "true"} -> true
      {:ok, "false"} -> false
      {:ok, result} when is_binary(result) -> result != "" and result != "0"
      {:ok, result} -> !!result
      {:error, _} -> false
    end
  end

  defp evaluate_condition(_, _, _), do: true
end
