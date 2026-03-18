defmodule Fizz.Workflows.Compiler.Assembler do
  @moduledoc false

  require Runic

  alias Fizz.Steps.Executors.Aggregator, as: AggregatorExecutor
  alias Fizz.Workflows.Expressions.AccessPlan
  alias Fizz.Workflows.Runtime.ConfigResolver
  alias Runic.Workflow

  @zip_join_modes ~w(zip_nil zip_shortest zip_cycle)

  @spec assemble(map()) :: {:ok, Runic.Workflow.t()} | {:error, [map()]}
  def assemble(ir) when is_map(ir) do
    referenced_step_ids = referenced_step_ids(ir.steps)
    accumulators = build_accumulators(referenced_step_ids)
    step_scopes = compute_step_scopes(ir)
    steps = build_steps(ir.steps, accumulators, step_scopes)

    workflow =
      Workflow.new(name: ir.definition_version_id || "fizz_workflow")
      |> Map.put(:fizz_metadata, %{compiler_version: ir.compiler_version})
      |> add_steps(ir, steps, accumulators)
      |> draw_meta_ref_edges(steps)

    {:ok, workflow}
  rescue
    exception ->
      {:error, [%{message: Exception.message(exception)}]}
  end

  defp add_steps(workflow, ir, steps, accumulators) do
    Enum.reduce(ir.topo_order, workflow, fn step_id, acc ->
      step_data = Map.fetch!(steps, step_id)
      {acc, parent_sources} = resolve_parent_sources(acc, ir, steps, step_id)
      parent_refs = Enum.map(parent_sources, & &1.parent_ref)

      acc =
        case Map.get(step_data, :kind) do
          :join ->
            add_explicit_join_step(acc, step_data, parent_sources)

          _ ->
            step_data.entry_specs
            |> Enum.reduce(acc, fn spec, workflow_acc ->
              add_component_spec(workflow_acc, spec, parent_refs)
            end)
            |> then(fn workflow_acc ->
              Enum.reduce(step_data.internal_specs, workflow_acc, &add_component_spec(&2, &1))
            end)
        end

      case Map.get(accumulators, step_id) do
        nil ->
          acc

        accumulator ->
          Enum.reduce(step_data.capture_refs, acc, fn parent_ref, workflow_acc ->
            Workflow.add(workflow_acc, accumulator, to: parent_ref, validate: :off)
          end)
      end
    end)
  end

  defp add_explicit_join_step(workflow, step_data, parent_sources) do
    parent_contexts =
      Map.new(step_data.parent_contexts, fn context -> {context.source_step_id, context} end)

    {workflow, normalized_refs} =
      parent_sources
      |> Enum.with_index()
      |> Enum.reduce({workflow, []}, fn {parent_source, index}, {workflow_acc, refs} ->
        context = Map.fetch!(parent_contexts, parent_source.source_step_id)

        {workflow_acc, ref} =
          normalize_join_parent_ref(
            workflow_acc,
            step_data,
            parent_source,
            context,
            index
          )

        {workflow_acc, refs ++ [ref]}
      end)

    add_component(workflow, step_data.component, normalized_refs, :all)
  end

  defp normalize_join_parent_ref(
         workflow,
         %{step_id: join_id, join_has_split?: true},
         %{parent_ref: parent_ref},
         %{lineage: []},
         index
       ) do
    wrapper_name = "#{join_id}__branch__#{index}__singleton"
    wrapper = singleton_array_step(wrapper_name)

    {Workflow.add(workflow, wrapper, to: parent_ref, validate: :off), wrapper_name}
  end

  defp normalize_join_parent_ref(
         workflow,
         %{},
         %{parent_ref: parent_ref},
         %{lineage: []},
         _index
       ) do
    {workflow, parent_ref}
  end

  defp normalize_join_parent_ref(
         workflow,
         %{step_id: join_id},
         %{parent_ref: parent_ref},
         %{lineage: lineage},
         index
       ) do
    reducer_name = "#{join_id}__branch__#{index}__collect"
    empty_condition_name = "#{join_id}__branch__#{index}__empty"
    empty_default_name = "#{join_id}__branch__#{index}__default"
    output_name = "#{join_id}__branch__#{index}__collected"
    mapped_from = List.last(lineage)

    reduce =
      build_collect_reduce_component(reducer_name, mapped_from)

    empty_condition = build_empty_collection_condition(empty_condition_name)
    empty_default = constant_step(empty_default_name, [])
    output_union = passthrough_step(output_name)

    workflow =
      workflow
      |> Workflow.add(reduce, to: parent_ref, validate: :off)
      |> Workflow.add(empty_condition, to: splitter_extractor_name(mapped_from), validate: :off)
      |> Workflow.add(empty_default, to: empty_condition_name, validate: :off)
      |> add_component(output_union, [{reducer_name, :fan_in}, empty_default_name], :any)

    {workflow, output_name}
  end

  defp add_component_spec(workflow, %{component: component} = spec, parent_refs) do
    parents = Map.get(spec, :parents, parent_refs)
    parent_mode = Map.get(spec, :parent_mode, :all)
    add_component(workflow, component, parents, parent_mode)
  end

  defp add_component_spec(workflow, %{component: component, parents: parents} = spec) do
    parent_mode = Map.get(spec, :parent_mode, :all)
    add_component(workflow, component, parents, parent_mode)
  end

  defp add_component(workflow, component, [], _parent_mode) do
    Workflow.add(workflow, component, validate: :off)
  end

  defp add_component(workflow, component, [parent_ref], _parent_mode) do
    Workflow.add(workflow, component, to: parent_ref, validate: :off)
  end

  defp add_component(workflow, component, parent_refs, :any) do
    Enum.reduce(parent_refs, workflow, fn parent_ref, workflow_acc ->
      Workflow.add(workflow_acc, component, to: parent_ref, validate: :off)
    end)
  end

  defp add_component(workflow, component, parent_refs, _parent_mode) do
    Workflow.add(workflow, component, to: parent_refs, validate: :off)
  end

  defp draw_meta_ref_edges(workflow, steps) do
    steps
    |> Map.values()
    |> Enum.flat_map(& &1.meta_targets)
    |> Enum.reduce(workflow, fn %{hash: hash, meta_refs: meta_refs}, workflow_acc ->
      Enum.reduce(meta_refs, workflow_acc, fn meta_ref, edge_acc ->
        case meta_ref.kind do
          :state_of ->
            Workflow.draw_meta_ref_edge(edge_acc, hash, meta_ref.target, meta_ref)

          _ ->
            edge_acc
        end
      end)
    end)
  end

  defp resolve_parent_sources(workflow, ir, steps, step_id) do
    step_id
    |> incoming_connections(ir.connections)
    |> ordered_connection_groups()
    |> Enum.reduce({workflow, []}, fn {source_step_id, connections},
                                      {workflow_acc, parent_sources} ->
      source_step = Map.fetch!(steps, source_step_id)

      refs =
        connections
        |> Enum.flat_map(fn connection ->
          source_refs_for(source_step, connection.source_output)
        end)
        |> Enum.uniq()

      case refs do
        [] ->
          raise ArgumentError,
                "connection from `#{source_step_id}` to `#{step_id}` references an unknown output handle"

        [ref] ->
          {workflow_acc,
           parent_sources ++
             [%{source_step_id: source_step_id, connections: connections, parent_ref: ref}]}

        _multiple_refs ->
          {workflow_acc, union_ref} =
            add_parent_union(workflow_acc, step_id, source_step_id, refs)

          {workflow_acc,
           parent_sources ++
             [%{source_step_id: source_step_id, connections: connections, parent_ref: union_ref}]}
      end
    end)
  end

  defp add_parent_union(workflow, target_step_id, source_step_id, refs) do
    union_name = "#{target_step_id}__from__#{source_step_id}__union"
    union_step = passthrough_step(union_name)

    workflow =
      Enum.reduce(refs, workflow, fn ref, workflow_acc ->
        Workflow.add(workflow_acc, union_step, to: ref, validate: :off)
      end)

    {workflow, union_name}
  end

  defp build_accumulators(step_ids) do
    Map.new(step_ids, fn step_id ->
      accumulator_name = "#{step_id}__output"

      accumulator =
        Runic.accumulator(nil, fn value, _state -> value end, name: ^accumulator_name)

      {step_id, accumulator}
    end)
  end

  defp build_steps(steps, accumulators, step_scopes) do
    Map.new(steps, fn {step_id, step} ->
      {step_id, build_step(step, accumulators, Map.get(step_scopes, step_id))}
    end)
  end

  defp build_step(step, accumulators, step_scope) do
    meta_refs = build_meta_refs(step.dependencies, accumulators)

    case step.type_id do
      "splitter" ->
        build_splitter_step(step, meta_refs)

      "aggregator" ->
        build_aggregator_step(step, meta_refs, step_scope)

      "join" ->
        build_join_step(step, meta_refs, step_scope)

      "condition" ->
        build_condition_step(step, meta_refs)

      "switch" ->
        build_switch_step(step, meta_refs)

      _ ->
        build_plain_step(step, meta_refs)
    end
  end

  defp build_plain_step(step, meta_refs) do
    component = build_executor_component(step, step.id, meta_refs)

    %{
      entry_specs: [%{component: component}],
      internal_specs: [],
      source_refs: %{"main" => [step.id]},
      capture_refs: [step.id],
      meta_targets: meta_targets(component, meta_refs)
    }
  end

  defp build_splitter_step(step, meta_refs) do
    extractor_name = "#{step.id}__extract"
    extractor = build_executor_component(step, extractor_name, meta_refs)
    map_name = step.id
    map_component = Runic.map(fn item -> item end, name: ^map_name)

    %{
      entry_specs: [%{component: extractor}],
      internal_specs: [%{component: map_component, parents: [extractor_name]}],
      source_refs: %{"main" => [{step.id, :leaf}]},
      capture_refs: [{step.id, :leaf}],
      meta_targets: meta_targets(extractor, meta_refs)
    }
  end

  defp build_aggregator_step(step, meta_refs, step_scope) do
    operation =
      required_literal_string!(Map.get(step.compiled_config, "operation"), "aggregator operation")

    mapped_from = step_scope.reducer_map

    if is_binary(mapped_from) do
      reduce_name = "#{step.id}__reduce"
      empty_condition_name = "#{step.id}__empty"
      empty_default_name = "#{step.id}__default"
      output_union = passthrough_step(step.id)

      reduce =
        build_aggregator_reduce_component(
          reduce_name,
          operation,
          step.compiled_config,
          step.dependencies,
          meta_refs,
          mapped_from
        )

      empty_condition = build_empty_collection_condition(empty_condition_name)

      empty_default =
        build_aggregate_empty_component(
          empty_default_name,
          step.compiled_config,
          step.dependencies,
          meta_refs
        )

      %{
        entry_specs: [
          %{component: reduce},
          %{component: empty_condition, parents: [splitter_extractor_name(mapped_from)]}
        ],
        internal_specs: [
          %{component: empty_default, parents: [empty_condition_name]},
          %{
            component: output_union,
            parents: [{reduce_name, :fan_in}, empty_default_name],
            parent_mode: :any
          }
        ],
        source_refs: %{"main" => [step.id]},
        capture_refs: [step.id],
        meta_targets:
          meta_targets(reduce, meta_refs) ++
            meta_targets(empty_default, meta_refs)
      }
    else
      component =
        build_aggregator_reduce_component(
          step.id,
          operation,
          step.compiled_config,
          step.dependencies,
          meta_refs,
          nil
        )

      %{
        entry_specs: [%{component: component}],
        internal_specs: [],
        source_refs: %{"main" => [{step.id, :fan_in}]},
        capture_refs: [{step.id, :fan_in}],
        meta_targets: meta_targets(component, meta_refs)
      }
    end
  end

  defp build_join_step(step, meta_refs, step_scope) do
    compiled_step =
      %{
        step
        | compiled_config: put_effective_join_mode(step.compiled_config, step_scope.join_mode)
      }

    component = build_executor_component(compiled_step, step.id, meta_refs)

    %{
      kind: :join,
      step_id: step.id,
      component: component,
      parent_contexts: step_scope.parent_contexts,
      join_has_split?: step_scope.join_has_split?,
      source_refs: %{"main" => [step.id]},
      capture_refs: [step.id],
      meta_targets: meta_targets(component, meta_refs)
    }
  end

  defp build_condition_step(step, meta_refs) do
    true_output = optional_literal_string(Map.get(step.compiled_config, "true_output"), "true")
    false_output = optional_literal_string(Map.get(step.compiled_config, "false_output"), "false")

    true_branch_name = "#{step.id}__branch__0"
    false_branch_name = "#{step.id}__branch__1"
    true_condition_name = "#{true_branch_name}__condition"
    false_condition_name = "#{false_branch_name}__condition"
    main_union = passthrough_step(step.id)

    true_condition = build_condition_component(step, meta_refs, true_condition_name, true)
    false_condition = build_condition_component(step, meta_refs, false_condition_name, false)
    true_reaction = passthrough_step(true_branch_name)
    false_reaction = passthrough_step(false_branch_name)

    %{
      entry_specs: [%{component: true_condition}, %{component: false_condition}],
      internal_specs: [
        %{component: true_reaction, parents: [true_condition_name]},
        %{component: false_reaction, parents: [false_condition_name]},
        %{
          component: main_union,
          parents: [true_branch_name, false_branch_name],
          parent_mode: :any
        }
      ],
      source_refs:
        %{"main" => [step.id]}
        |> Map.update(true_output, [true_branch_name], fn refs -> refs ++ [true_branch_name] end)
        |> Map.update(false_output, [false_branch_name], fn refs ->
          refs ++ [false_branch_name]
        end),
      capture_refs: [step.id],
      meta_targets: []
    }
  end

  defp build_switch_step(step, meta_refs) do
    {case_specs, source_refs} =
      step.compiled_config
      |> Map.get("cases", [])
      |> Enum.with_index()
      |> Enum.reduce({[], %{"main" => [step.id]}}, fn {case_config, index},
                                                      {component_specs, refs_acc} ->
        output = required_literal_string!(Map.get(case_config, "output"), "switch case output")
        branch_name = "#{step.id}__branch__#{index}"
        condition_name = "#{branch_name}__condition"

        condition =
          build_switch_condition_component(step, meta_refs, condition_name, {:case, index})

        reaction = passthrough_step(branch_name)

        {
          component_specs ++
            [%{component: condition}, %{component: reaction, parents: [condition_name]}],
          Map.update(refs_acc, output, [branch_name], fn refs -> refs ++ [branch_name] end)
        }
      end)

    default_output =
      optional_literal_string(Map.get(step.compiled_config, "default_output"), "default")

    default_branch_name = "#{step.id}__branch__default"
    default_condition_name = "#{default_branch_name}__condition"

    default_condition =
      build_switch_condition_component(step, meta_refs, default_condition_name, :default)

    default_reaction = passthrough_step(default_branch_name)
    main_union = passthrough_step(step.id)

    %{
      entry_specs:
        Enum.filter(case_specs, fn spec -> Map.get(spec, :parents) == nil end) ++
          [%{component: default_condition}],
      internal_specs:
        Enum.filter(case_specs, fn spec -> Map.get(spec, :parents) != nil end) ++
          [
            %{component: default_reaction, parents: [default_condition_name]},
            %{
              component: main_union,
              parents:
                Enum.map(case_specs, fn spec -> spec.component.name end)
                |> Enum.reject(&String.ends_with?(&1, "__condition"))
                |> Kernel.++([default_branch_name]),
              parent_mode: :any
            }
          ],
      source_refs:
        Map.update(source_refs, default_output, [default_branch_name], fn refs ->
          refs ++ [default_branch_name]
        end),
      capture_refs: [step.id],
      meta_targets: []
    }
  end

  defp build_aggregator_reduce_component(
         name,
         operation,
         compiled_config,
         _dependencies,
         [],
         mapped_from
       ) do
    Runic.reduce(
      AggregatorExecutor.init_for_operation(operation),
      fn item, acc ->
        __MODULE__.aggregate_reduce(item, acc, ^compiled_config)
      end,
      name: ^name,
      map: ^mapped_from
    )
  end

  defp build_aggregator_reduce_component(
         name,
         operation,
         compiled_config,
         dependencies,
         meta_refs,
         mapped_from
       ) do
    Runic.reduce(
      AggregatorExecutor.init_for_operation(operation),
      fn item, acc, meta_ctx ->
        __MODULE__.aggregate_reduce(item, acc, meta_ctx, ^compiled_config, ^dependencies)
      end,
      name: ^name,
      map: ^mapped_from
    )
    |> put_reduce_meta_refs(meta_refs)
  end

  defp build_collect_reduce_component(name, mapped_from) do
    Runic.reduce(
      AggregatorExecutor.init_for_operation("collect"),
      fn item, acc ->
        AggregatorExecutor.reducer_for_operation("collect").(item, acc)
      end,
      name: ^name,
      map: ^mapped_from
    )
  end

  defp build_aggregate_empty_component(name, compiled_config, _dependencies, []) do
    Runic.step(
      fn input ->
        __MODULE__.aggregate_empty_result(input, compiled_config)
      end,
      name: ^name
    )
  end

  defp build_aggregate_empty_component(name, compiled_config, dependencies, meta_refs) do
    Runic.step(
      fn input, meta_ctx ->
        __MODULE__.aggregate_empty_result(input, meta_ctx, compiled_config, dependencies)
      end,
      name: ^name
    )
    |> Map.put(:meta_refs, meta_refs)
  end

  defp build_empty_collection_condition(name) do
    Runic.condition(
      fn input ->
        __MODULE__.empty_collection?(input)
      end,
      name: ^name
    )
  end

  defp singleton_array_step(name) do
    Runic.step(
      fn input ->
        [input]
      end,
      name: ^name
    )
  end

  defp constant_step(name, value) do
    Runic.step(
      fn _input ->
        value
      end,
      name: ^name
    )
  end

  defp build_executor_component(step, name, []) do
    executor = step.executor
    compiled_config = step.compiled_config
    step_context = base_step_context(step)

    Runic.step(
      fn input ->
        config =
          ConfigResolver.resolve_config(^compiled_config, %{
            input: input,
            steps: %{},
            workflow: %{},
            env: %{}
          })

        execute_executor(^executor, config, input, executor_context(input, %{}, ^step_context))
      end,
      name: ^name
    )
  end

  defp build_executor_component(step, name, meta_refs) do
    executor = step.executor
    compiled_config = step.compiled_config
    step_context = base_step_context(step)
    dependencies = step.dependencies

    Runic.step(
      fn input, meta_ctx ->
        resolution_context = resolution_context(input, meta_ctx, ^dependencies)
        config = ConfigResolver.resolve_config(^compiled_config, resolution_context)

        execute_executor(
          ^executor,
          config,
          input,
          executor_context(input, resolution_context, ^step_context)
        )
      end,
      name: ^name
    )
    |> Map.put(:meta_refs, meta_refs)
  end

  defp build_condition_component(step, [], name, branch) do
    executor = step.executor
    compiled_config = step.compiled_config

    Runic.condition(
      fn input ->
        __MODULE__.condition_branch_matches(input, compiled_config, executor, branch)
      end,
      name: ^name
    )
  end

  defp build_condition_component(step, meta_refs, name, branch) do
    executor = step.executor
    compiled_config = step.compiled_config
    dependencies = step.dependencies

    Runic.condition(
      fn input, meta_ctx ->
        __MODULE__.condition_branch_matches(
          input,
          meta_ctx,
          compiled_config,
          dependencies,
          executor,
          branch
        )
      end,
      name: ^name
    )
    |> Map.put(:meta_refs, meta_refs)
  end

  defp build_switch_condition_component(step, [], name, branch_match) do
    compiled_config = step.compiled_config

    Runic.condition(
      fn input ->
        __MODULE__.switch_branch_matches(input, compiled_config, branch_match)
      end,
      name: ^name
    )
  end

  defp build_switch_condition_component(step, meta_refs, name, branch_match) do
    compiled_config = step.compiled_config
    dependencies = step.dependencies

    Runic.condition(
      fn input, meta_ctx ->
        __MODULE__.switch_branch_matches(
          input,
          meta_ctx,
          compiled_config,
          dependencies,
          branch_match
        )
      end,
      name: ^name
    )
    |> Map.put(:meta_refs, meta_refs)
  end

  defp put_reduce_meta_refs(reduce, []), do: reduce

  defp put_reduce_meta_refs(reduce, meta_refs) do
    %{reduce | fan_in: %{reduce.fan_in | meta_refs: meta_refs}}
  end

  defp meta_targets(_component, []), do: []

  defp meta_targets(%Runic.Workflow.Reduce{} = component, meta_refs) do
    [%{hash: component.fan_in.hash, meta_refs: meta_refs}]
  end

  defp meta_targets(component, meta_refs) do
    [%{hash: component.hash, meta_refs: meta_refs}]
  end

  defp build_meta_refs(dependencies, accumulators) do
    step_refs =
      Enum.map(dependencies.step_ids, fn step_id ->
        accumulator = Map.fetch!(accumulators, step_id)

        %{
          kind: :state_of,
          target: accumulator.hash,
          field_path: [],
          context_key: {:step_output, step_id}
        }
      end)

    runtime_refs =
      Enum.map(dependencies.runtime_keys, fn
        runtime_key when runtime_key in [:workflow, :env, :_credential_resolver] ->
          %{
            kind: :context,
            target: runtime_key,
            field_path: [],
            context_key: runtime_key
          }
      end)

    step_refs ++ runtime_refs
  end

  defp compute_step_scopes(ir) do
    Enum.reduce(ir.topo_order, %{}, fn step_id, scopes ->
      step = Map.fetch!(ir.steps, step_id)
      parent_contexts = incoming_parent_contexts(step_id, ir.connections, scopes)

      validate_split_convergence!(step, parent_contexts)

      reducer_map = compute_reducer_map(step, parent_contexts)
      join_info = compute_join_info(step, parent_contexts)
      outgoing_lineage = compute_outgoing_lineage(step, parent_contexts, reducer_map, join_info)

      Map.put(scopes, step_id, %{
        parent_contexts: parent_contexts,
        reducer_map: reducer_map,
        outgoing_lineage: outgoing_lineage,
        join_mode: Map.get(join_info, :mode),
        join_has_split?: Map.get(join_info, :has_split?, false)
      })
    end)
  end

  defp incoming_parent_contexts(step_id, connections, scopes) do
    step_id
    |> incoming_connections(connections)
    |> ordered_connection_groups()
    |> Enum.map(fn {source_step_id, source_connections} ->
      parent_scope = Map.get(scopes, source_step_id, %{outgoing_lineage: []})

      %{
        source_step_id: source_step_id,
        lineage: Map.get(parent_scope, :outgoing_lineage, []),
        connections: source_connections
      }
    end)
  end

  defp validate_split_convergence!(%{type_id: "join"}, _parent_contexts), do: :ok

  defp validate_split_convergence!(step, parent_contexts) do
    if length(parent_contexts) > 1 and Enum.any?(parent_contexts, &split_lineage?(&1.lineage)) do
      raise ArgumentError,
            "step `#{step.id}` merges split-derived parents implicitly; insert an explicit `join` step"
    end
  end

  defp compute_reducer_map(%{type_id: "aggregator", id: step_id}, parent_contexts) do
    case parent_contexts
         |> Enum.map(&effective_splitter(&1.lineage))
         |> Enum.reject(&is_nil/1)
         |> Enum.uniq() do
      [] ->
        nil

      [map_id] ->
        map_id

      map_ids ->
        raise ArgumentError,
              "aggregator `#{step_id}` has multiple upstream splitters: #{Enum.join(Enum.sort(map_ids), ", ")}"
    end
  end

  defp compute_reducer_map(_step, _parent_contexts), do: nil

  defp compute_join_info(
         %{type_id: "join", id: step_id, compiled_config: compiled_config},
         parent_contexts
       ) do
    explicit_mode = optional_literal_string(Map.get(compiled_config, "mode"), nil)
    has_split? = Enum.any?(parent_contexts, &split_lineage?(&1.lineage))

    normalized_lineages =
      parent_contexts
      |> Enum.map(&normalized_join_lineage(&1.lineage))
      |> unique_lineages()

    if length(normalized_lineages) > 1 do
      raise ArgumentError,
            "join `#{step_id}` mixes split parents at different depths; aggregate deeper branches before joining"
    end

    original_lineages =
      parent_contexts
      |> Enum.map(& &1.lineage)
      |> unique_lineages()

    split_and_non_split? = has_split? and Enum.any?(parent_contexts, &(&1.lineage == []))
    same_original_lineage? = length(original_lineages) <= 1

    mode =
      explicit_mode ||
        cond do
          not has_split? -> "wait_all"
          split_and_non_split? or not same_original_lineage? -> "cartesian"
          true -> "zip_nil"
        end

    validate_join_mode!(
      step_id,
      mode,
      has_split?,
      split_and_non_split?,
      same_original_lineage?
    )

    %{
      mode: mode,
      has_split?: has_split?,
      outgoing_lineage: List.first(normalized_lineages) || []
    }
  end

  defp compute_join_info(_step, _parent_contexts), do: %{}

  defp validate_join_mode!(step_id, "wait_all", true, _split_and_non_split?, _same_original?) do
    raise ArgumentError,
          "join `#{step_id}` mode `wait_all` cannot be used with split-derived parents"
  end

  defp validate_join_mode!(step_id, mode, true, split_and_non_split?, same_original?)
       when mode in @zip_join_modes do
    cond do
      split_and_non_split? ->
        raise ArgumentError,
              "join `#{step_id}` must use `cartesian` when mixing split and non-split parents"

      not same_original? ->
        raise ArgumentError,
              "join `#{step_id}` mode `#{mode}` requires all split parents to share the same lineage and depth"

      true ->
        :ok
    end
  end

  defp validate_join_mode!(step_id, mode, true, split_and_non_split?, same_original?) do
    if mode != "cartesian" and (split_and_non_split? or not same_original?) do
      raise ArgumentError,
            "join `#{step_id}` must use `cartesian` for mixed split lineages"
    end
  end

  defp validate_join_mode!(_step_id, _mode, _has_split?, _split_and_non_split?, _same_original?),
    do: :ok

  defp compute_outgoing_lineage(step, parent_contexts, reducer_map, join_info) do
    base_lineage =
      parent_contexts
      |> Enum.map(& &1.lineage)
      |> unique_lineages()
      |> List.first() || []

    case step.type_id do
      "splitter" ->
        base_lineage ++ [step.id]

      "aggregator" when is_binary(reducer_map) ->
        pop_effective_splitter(base_lineage, reducer_map, step.id)

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

  defp normalized_join_lineage([]), do: []
  defp normalized_join_lineage(lineage), do: Enum.drop(lineage, -1)

  defp passthrough_step(name) do
    Runic.step(fn input -> input end, name: ^name)
  end

  defp splitter_extractor_name(step_id), do: "#{step_id}__extract"

  defp source_refs_for(%{source_refs: source_refs}, output_handle) do
    Map.get(source_refs, output_handle, [])
  end

  defp incoming_connections(step_id, connections) do
    Enum.filter(connections, &(&1.target_step_id == step_id))
  end

  defp ordered_connection_groups(connections) do
    {order, grouped} =
      Enum.reduce(connections, {[], %{}}, fn connection, {order, grouped} ->
        source_step_id = connection.source_step_id

        if Map.has_key?(grouped, source_step_id) do
          {order, Map.update!(grouped, source_step_id, &(&1 ++ [connection]))}
        else
          {order ++ [source_step_id], Map.put(grouped, source_step_id, [connection])}
        end
      end)

    Enum.map(order, fn source_step_id -> {source_step_id, Map.fetch!(grouped, source_step_id)} end)
  end

  defp base_step_context(step) do
    %{
      step_id: step.id,
      step_name: step.name,
      type_id: step.type_id
    }
  end

  defp resolution_context(input, meta_ctx, dependencies) do
    %{
      input: input,
      steps:
        dependencies.step_ids
        |> Enum.reduce(%{}, fn step_id, acc ->
          Map.put(acc, step_id, Map.get(meta_ctx, {:step_output, step_id}))
        end),
      workflow: Map.get(meta_ctx, :workflow) || %{},
      env: Map.get(meta_ctx, :env) || %{},
      _credential_resolver: Map.get(meta_ctx, :_credential_resolver)
    }
  end

  defp executor_context(input, resolution_context, step_context) do
    Map.merge(step_context, %{
      input: input,
      steps: Map.get(resolution_context, :steps, %{}),
      workflow: Map.get(resolution_context, :workflow, %{}),
      env: Map.get(resolution_context, :env, %{})
    })
  end

  defp execute_executor(executor, config, input, context) do
    case executor.execute(config, input, context) do
      {:ok, output} -> output
      {:skip, reason} -> {:skip, reason}
      {:error, reason} -> raise "step execution failed: #{inspect(reason)}"
      other -> other
    end
  end

  defp matched_switch_branch(config) do
    value = Map.get(config, "value")
    cases = Map.get(config, "cases", [])

    case Enum.find_index(cases, fn case_def ->
           normalize_switch_value(value) == normalize_switch_value(Map.get(case_def, "match"))
         end) do
      nil -> :default
      index -> {:case, index}
    end
  end

  defp branch_match?(matched_branch, expected_branch), do: matched_branch == expected_branch

  defp normalize_switch_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_switch_value(value) when is_number(value), do: to_string(value)
  defp normalize_switch_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_switch_value(value), do: value

  defp normalize_aggregator_operation(operation) when is_binary(operation), do: operation
  defp normalize_aggregator_operation(_operation), do: "collect"

  @doc false
  def aggregate_reduce(item, acc, compiled_config) do
    config =
      ConfigResolver.resolve_config(compiled_config, %{
        input: item,
        steps: %{},
        workflow: %{},
        env: %{}
      })

    operation =
      config
      |> Map.get("operation", "collect")
      |> normalize_aggregator_operation()

    AggregatorExecutor.reducer_for_operation(operation).(item, acc)
  end

  @doc false
  def aggregate_reduce(item, acc, meta_ctx, compiled_config, dependencies) do
    resolution_context = resolution_context(item, meta_ctx, dependencies)
    config = ConfigResolver.resolve_config(compiled_config, resolution_context)

    operation =
      config
      |> Map.get("operation", "collect")
      |> normalize_aggregator_operation()

    AggregatorExecutor.reducer_for_operation(operation).(item, acc)
  end

  @doc false
  def aggregate_empty_result(input, compiled_config) do
    compiled_config
    |> ConfigResolver.resolve_config(%{
      input: input,
      steps: %{},
      workflow: %{},
      env: %{}
    })
    |> Map.get("operation", "collect")
    |> normalize_aggregator_operation()
    |> AggregatorExecutor.init_for_operation()
  end

  @doc false
  def aggregate_empty_result(input, meta_ctx, compiled_config, dependencies) do
    input
    |> resolution_context(meta_ctx, dependencies)
    |> then(&ConfigResolver.resolve_config(compiled_config, &1))
    |> Map.get("operation", "collect")
    |> normalize_aggregator_operation()
    |> AggregatorExecutor.init_for_operation()
  end

  @doc false
  def empty_collection?(input) when is_list(input), do: input == []
  def empty_collection?(input) when is_map(input), do: map_size(input) == 0
  def empty_collection?(%Range{} = input), do: Enum.empty?(input)
  def empty_collection?(nil), do: true
  def empty_collection?(_input), do: false

  @doc false
  def condition_branch_matches(input, compiled_config, executor, branch) do
    config =
      ConfigResolver.resolve_config(compiled_config, %{
        input: input,
        steps: %{},
        workflow: %{},
        env: %{}
      })

    case {branch, executor.execute(config, input, %{})} do
      {true, {:ok, _output}} -> true
      {false, {:skip, :condition_false}} -> true
      _ -> false
    end
  end

  @doc false
  def condition_branch_matches(input, meta_ctx, compiled_config, dependencies, executor, branch) do
    resolution_context = resolution_context(input, meta_ctx, dependencies)
    config = ConfigResolver.resolve_config(compiled_config, resolution_context)

    case {branch, executor.execute(config, input, %{})} do
      {true, {:ok, _output}} -> true
      {false, {:skip, :condition_false}} -> true
      _ -> false
    end
  end

  @doc false
  def switch_branch_matches(input, compiled_config, branch_match) do
    config =
      ConfigResolver.resolve_config(compiled_config, %{
        input: input,
        steps: %{},
        workflow: %{},
        env: %{}
      })

    branch_match?(matched_switch_branch(config), branch_match)
  end

  @doc false
  def switch_branch_matches(input, meta_ctx, compiled_config, dependencies, branch_match) do
    resolution_context = resolution_context(input, meta_ctx, dependencies)
    config = ConfigResolver.resolve_config(compiled_config, resolution_context)

    branch_match?(matched_switch_branch(config), branch_match)
  end

  defp put_effective_join_mode(compiled_config, mode) do
    Map.put(compiled_config, "mode", %AccessPlan.Literal{value: mode})
  end

  defp optional_literal_string(nil, default), do: default
  defp optional_literal_string(%AccessPlan.Literal{value: nil}, default), do: default

  defp optional_literal_string(%AccessPlan.Literal{value: value}, _default) when is_binary(value),
    do: value

  defp optional_literal_string(%AccessPlan.Literal{value: value}, label) do
    raise ArgumentError, "#{label} must resolve to a string literal, got: #{inspect(value)}"
  end

  defp optional_literal_string(value, _default) when is_binary(value), do: value

  defp optional_literal_string(value, label) do
    raise ArgumentError, "#{label} must resolve to a string literal, got: #{inspect(value)}"
  end

  defp required_literal_string!(nil, label) do
    raise ArgumentError, "#{label} must resolve to a string literal, got: nil"
  end

  defp required_literal_string!(%AccessPlan.Literal{value: nil}, label) do
    raise ArgumentError, "#{label} must resolve to a string literal, got: nil"
  end

  defp required_literal_string!(value, label), do: optional_literal_string(value, label)

  defp referenced_step_ids(steps) do
    steps
    |> Map.values()
    |> Enum.flat_map(& &1.dependencies.step_ids)
    |> Enum.uniq()
  end
end
