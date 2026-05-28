defmodule Fizz.Workflows.Compiler.ScopePlanner do
  @moduledoc false

  import Fizz.Workflows.Compiler.CompiledConfig,
    only: [optional_literal_string: 2, required_literal_string!: 2]

  @row_safe_implicit_aggregator_operations ~w(collect count first last)

  @spec plan!([String.t()], map(), map()) :: map()
  def plan!(topo_order, steps, connection_indexes)
      when is_list(topo_order) and is_map(steps) and is_map(connection_indexes) do
    Enum.reduce(topo_order, %{}, fn step_id, scopes ->
      step = Map.fetch!(steps, step_id)
      parent_contexts = parent_contexts(step_id, connection_indexes, scopes)

      validate_split_convergence!(step, parent_contexts)

      aggregator_info = aggregator_info(step, parent_contexts)
      join_info = join_info(step, parent_contexts)

      outgoing_lineage =
        outgoing_lineage(step, parent_contexts, aggregator_info, join_info)

      Map.put(scopes, step_id, %{
        parent_contexts: parent_contexts,
        reducer_map: Map.get(aggregator_info, :reducer_map),
        implicit_aggregator_join?: Map.get(aggregator_info, :implicit_join?, false),
        outgoing_lineage: outgoing_lineage,
        join_mode: Map.get(join_info, :mode),
        join_has_split?: Map.get(join_info, :has_split?, false)
      })
    end)
  end

  defp parent_contexts(step_id, connection_indexes, scopes) do
    step_id
    |> flow_connections_to(connection_indexes)
    |> group_connections_by_source()
    |> Enum.map(fn {source_step_id, source_connections} ->
      parent_scope = Map.get(scopes, source_step_id, %{outgoing_lineage: []})

      %{
        source_step_id: source_step_id,
        lineage: Map.get(parent_scope, :outgoing_lineage, []),
        connections: source_connections
      }
    end)
  end

  defp flow_connections_to(step_id, connection_indexes) do
    connection_indexes
    |> Map.fetch!(:incoming)
    |> Map.get(step_id, [])
    |> Enum.reverse()
    |> Enum.filter(&(&1.target_step_id == step_id))
  end

  defp group_connections_by_source(connections) do
    {order, grouped} =
      Enum.reduce(connections, {[], %{}}, fn connection, {order, grouped} ->
        source_step_id = connection.source_step_id

        if Map.has_key?(grouped, source_step_id) do
          {order, Map.update!(grouped, source_step_id, &[connection | &1])}
        else
          {[source_step_id | order], Map.put(grouped, source_step_id, [connection])}
        end
      end)

    order
    |> Enum.reverse()
    |> Enum.map(fn source_step_id ->
      {source_step_id, grouped |> Map.fetch!(source_step_id) |> Enum.reverse()}
    end)
  end

  defp validate_split_convergence!(%{type_id: type_id}, _parent_contexts)
       when type_id in ["join", "aggregator"],
       do: :ok

  defp validate_split_convergence!(step, parent_contexts) do
    if length(parent_contexts) > 1 and Enum.any?(parent_contexts, &split_lineage?(&1.lineage)) do
      raise ArgumentError,
            "step `#{step.id}` merges split-derived parents implicitly; insert an explicit `join` step"
    end
  end

  defp aggregator_info(
         %{type_id: "aggregator", id: step_id, compiled_config: compiled_config},
         parent_contexts
       ) do
    operation =
      required_literal_string!(Map.get(compiled_config, "operation"), "aggregator operation")

    split_parent_contexts = Enum.filter(parent_contexts, &split_lineage?(&1.lineage))

    reducer_maps =
      split_parent_contexts
      |> Enum.map(&effective_splitter(&1.lineage))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    cond do
      split_parent_contexts == [] ->
        %{reducer_map: nil, implicit_join?: false}

      length(parent_contexts) == 1 and length(reducer_maps) == 1 ->
        %{reducer_map: List.first(reducer_maps), implicit_join?: false}

      true ->
        validate_implicit_aggregator_operation!(step_id, operation)
        %{reducer_map: nil, implicit_join?: true}
    end
  end

  defp aggregator_info(_step, _parent_contexts) do
    %{reducer_map: nil, implicit_join?: false}
  end

  defp join_info(
         %{type_id: "join", id: step_id, compiled_config: compiled_config},
         parent_contexts
       ) do
    explicit_mode = optional_literal_string(Map.get(compiled_config, "mode"), nil)
    has_split? = Enum.any?(parent_contexts, &split_lineage?(&1.lineage))

    mode =
      explicit_mode ||
        cond do
          not has_split? -> "wait_all"
          true -> "zip_nil"
        end

    validate_join_mode!(step_id, mode, has_split?)

    %{
      mode: mode,
      has_split?: has_split?,
      outgoing_lineage: []
    }
  end

  defp join_info(_step, _parent_contexts), do: %{}

  defp validate_join_mode!(step_id, "wait_all", true) do
    raise ArgumentError,
          "join `#{step_id}` mode `wait_all` cannot be used with split-derived parents"
  end

  defp validate_join_mode!(_step_id, _mode, _has_split?), do: :ok

  defp outgoing_lineage(step, parent_contexts, aggregator_info, join_info) do
    base_lineage =
      parent_contexts
      |> Enum.map(& &1.lineage)
      |> unique_lineages()
      |> List.first() || []

    case step.type_id do
      "splitter" ->
        base_lineage ++ [step.id]

      "aggregator" when aggregator_info.implicit_join? ->
        []

      "aggregator" when is_binary(aggregator_info.reducer_map) ->
        pop_effective_splitter(base_lineage, aggregator_info.reducer_map, step.id)

      "join" ->
        Map.get(join_info, :outgoing_lineage, [])

      _ ->
        base_lineage
    end
  end

  defp pop_effective_splitter(lineage, reducer_map, step_id) do
    case Enum.split(lineage, max(length(lineage) - 1, 0)) do
      {prefix, [^reducer_map]} ->
        prefix

      _ ->
        raise ArgumentError,
              "aggregator `#{step_id}` cannot reduce splitter `#{reducer_map}` from lineage #{inspect(lineage)}"
    end
  end

  defp unique_lineages(lineages) do
    Enum.reduce(lineages, [], fn lineage, acc ->
      if Enum.any?(acc, &(&1 == lineage)) do
        acc
      else
        acc ++ [lineage]
      end
    end)
  end

  defp split_lineage?([]), do: false
  defp split_lineage?(_lineage), do: true

  defp effective_splitter([]), do: nil
  defp effective_splitter(lineage), do: List.last(lineage)

  defp validate_implicit_aggregator_operation!(_step_id, operation)
       when operation in @row_safe_implicit_aggregator_operations,
       do: :ok

  defp validate_implicit_aggregator_operation!(step_id, operation) do
    supported = Enum.join(@row_safe_implicit_aggregator_operations, ", ")

    raise ArgumentError,
          "aggregator `#{step_id}` implicitly zips split-derived parents and only supports operations: #{supported}; add an explicit `join` or transform before using `#{operation}`"
  end
end
