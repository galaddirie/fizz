defmodule Fizz.Workflows.Compiler.Assembler do
  @moduledoc false

  require Runic

  alias Fizz.Steps.Executors.Aggregator, as: AggregatorExecutor
  alias Fizz.Workflows.Expressions.AccessPlan
  alias Fizz.Workflows.Runtime.ConfigResolver
  alias Runic.Workflow

  @spec assemble(map()) :: {:ok, Runic.Workflow.t()} | {:error, [map()]}
  def assemble(ir) when is_map(ir) do
    referenced_step_ids = referenced_step_ids(ir.steps)
    accumulators = build_accumulators(referenced_step_ids)
    map_scopes = compute_map_scopes(ir)
    steps = build_steps(ir.steps, accumulators, map_scopes)

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

      {acc, parent_refs} = resolve_parent_refs(acc, ir, steps, step_id)

      acc =
        step_data.entry_specs
        |> Enum.reduce(acc, fn spec, workflow_acc ->
          add_component_spec(workflow_acc, spec, parent_refs)
        end)
        |> then(fn workflow_acc ->
          Enum.reduce(step_data.internal_specs, workflow_acc, &add_component_spec(&2, &1))
        end)

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

  defp add_component_spec(workflow, %{component: component} = spec, parent_refs) do
    parent_mode = Map.get(spec, :parent_mode, :all)
    add_component(workflow, component, parent_refs, parent_mode)
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

  defp resolve_parent_refs(workflow, ir, steps, step_id) do
    step_id
    |> incoming_connections(ir.connections)
    |> Enum.group_by(& &1.source_step_id)
    |> Enum.reduce({workflow, []}, fn {source_step_id, connections},
                                      {workflow_acc, parent_refs} ->
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
          {workflow_acc, parent_refs ++ [ref]}

        _multiple_refs ->
          {workflow_acc, union_ref} =
            add_parent_union(workflow_acc, step_id, source_step_id, refs)

          {workflow_acc, parent_refs ++ [union_ref]}
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

  defp build_steps(steps, accumulators, map_scopes) do
    Map.new(steps, fn {step_id, step} ->
      {step_id, build_step(step, accumulators, Map.get(map_scopes, step_id))}
    end)
  end

  defp build_step(step, accumulators, map_scope) do
    meta_refs = build_meta_refs(step.dependencies, accumulators)

    case step.type_id do
      "splitter" ->
        build_splitter_step(step, meta_refs)

      "aggregator" ->
        build_aggregator_step(step, meta_refs, map_scope)

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

  defp build_aggregator_step(step, meta_refs, map_scope) do
    operation =
      required_literal_string!(Map.get(step.compiled_config, "operation"), "aggregator operation")

    reduce_name = step.id
    mapped_from = map_scope.reducer_map
    compiled_config = step.compiled_config
    dependencies = step.dependencies

    component =
      case meta_refs do
        [] ->
          Runic.reduce(
            AggregatorExecutor.init_for_operation(operation),
            fn item, acc ->
              __MODULE__.aggregate_reduce(item, acc, ^compiled_config)
            end,
            name: ^reduce_name,
            map: ^mapped_from
          )

        _ ->
          Runic.reduce(
            AggregatorExecutor.init_for_operation(operation),
            fn item, acc, meta_ctx ->
              __MODULE__.aggregate_reduce(item, acc, meta_ctx, ^compiled_config, ^dependencies)
            end,
            name: ^reduce_name,
            map: ^mapped_from
          )
          |> put_reduce_meta_refs(meta_refs)
      end

    %{
      entry_specs: [%{component: component}],
      internal_specs: [],
      source_refs: %{"main" => [{step.id, :fan_in}]},
      capture_refs: [{step.id, :fan_in}],
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

  defp compute_map_scopes(ir) do
    Enum.reduce(ir.topo_order, %{}, fn step_id, scopes ->
      incoming =
        step_id
        |> incoming_parent_ids(ir.connections)
        |> Enum.reduce(MapSet.new(), fn parent_id, acc ->
          parent_scope =
            scopes |> Map.get(parent_id, %{outgoing: MapSet.new()}) |> Map.get(:outgoing)

          MapSet.union(acc, parent_scope)
        end)

      reducer_map =
        case {ir.steps[step_id].type_id, MapSet.to_list(incoming)} do
          {"aggregator", []} ->
            nil

          {"aggregator", [map_id]} ->
            map_id

          {"aggregator", map_ids} ->
            raise ArgumentError,
                  "aggregator `#{step_id}` has multiple upstream splitters: #{Enum.join(Enum.sort(map_ids), ", ")}"

          _ ->
            nil
        end

      outgoing =
        case ir.steps[step_id].type_id do
          "splitter" ->
            MapSet.put(incoming, step_id)

          "aggregator" when is_binary(reducer_map) ->
            MapSet.delete(incoming, reducer_map)

          _ ->
            incoming
        end

      Map.put(scopes, step_id, %{incoming: incoming, reducer_map: reducer_map, outgoing: outgoing})
    end)
  end

  defp passthrough_step(name) do
    Runic.step(fn input -> input end, name: ^name)
  end

  defp source_refs_for(%{source_refs: source_refs}, output_handle) do
    Map.get(source_refs, output_handle, [])
  end

  defp incoming_connections(step_id, connections) do
    Enum.filter(connections, &(&1.target_step_id == step_id))
  end

  defp incoming_parent_ids(step_id, connections) do
    incoming_connections(step_id, connections)
    |> Enum.map(& &1.source_step_id)
    |> Enum.uniq()
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
