defmodule Fizz.Workflows.Compiler.Assembler do
  @moduledoc false

  require Runic

  alias Fizz.Integrations.Library.Fizz.Builtins.Aggregator, as: AggregatorExecutor
  alias Fizz.Integrations.Steps.ConnectionHandles
  alias Fizz.Workflows.Compiler.RuntimeCallbacks
  alias Fizz.Workflows.Compiler.ScopePlanner
  alias Fizz.Workflows.Expressions.AccessPlan
  alias Fizz.Workflows.Runtime.ConfigResolver
  alias Runic.Workflow

  import Fizz.Workflows.Compiler.CompiledConfig,
    only: [optional_literal_string: 2, required_literal_string!: 2]

  @spec assemble(map()) :: {:ok, Runic.Workflow.t()} | {:error, [map()]}
  def assemble(ir) when is_map(ir) do
    connection_indexes = build_connection_indexes(planned_flow_connections(ir))
    referenced_step_ids = referenced_step_ids(ir.steps)
    accumulators = build_accumulators(referenced_step_ids)
    dependency_input_assemblies = compute_dependency_input_assemblies(ir)
    step_scopes = ScopePlanner.plan!(ir.topo_order, ir.steps, connection_indexes)
    steps = build_steps(ir.steps, accumulators, step_scopes, dependency_input_assemblies)

    workflow =
      Workflow.new(name: ir.definition_version_id || "fizz_workflow")
      |> Map.put(:fizz_metadata, %{
        compiler_version: ir.compiler_version,
        trigger_manifest: trigger_manifest(ir.steps),
        result_step_ids: result_step_ids(ir, connection_indexes)
      })
      |> add_steps(ir, steps, accumulators, dependency_input_assemblies, connection_indexes)
      |> draw_meta_ref_edges(steps)

    {:ok, workflow}
  rescue
    exception ->
      {:error, [%{message: Exception.message(exception)}]}
  end

  defp add_steps(
         workflow,
         ir,
         steps,
         accumulators,
         dependency_input_assemblies,
         connection_indexes
       ) do
    Enum.reduce(ir.topo_order, workflow, fn step_id, acc ->
      step_data = Map.fetch!(steps, step_id)

      acc =
        case Map.get(step_data, :kind) do
          :join ->
            {acc, parent_sources} =
              resolve_parent_sources(
                acc,
                steps,
                step_id,
                connection_indexes
              )

            add_explicit_join_step(acc, step_data, parent_sources)

          :aggregator_join ->
            {acc, parent_sources} =
              resolve_parent_sources(
                acc,
                steps,
                step_id,
                connection_indexes
              )

            add_implicit_join_aggregator_step(acc, step_data, parent_sources)

          :with_dependencies ->
            {acc, parent_sources} =
              resolve_parent_sources(
                acc,
                steps,
                step_id,
                connection_indexes
              )

            dependency_input_assembly = Map.fetch!(dependency_input_assemblies, step_id)

            add_step_with_dependencies(
              acc,
              steps,
              step_data,
              parent_sources,
              dependency_input_assembly
            )

          _ ->
            {acc, parent_sources} =
              resolve_parent_sources(
                acc,
                steps,
                step_id,
                connection_indexes
              )

            parent_refs = Enum.map(parent_sources, & &1.parent_ref)

            step_data.entry_specs
            |> Enum.reduce(acc, fn spec, workflow_acc ->
              add_component_spec(workflow_acc, spec, parent_refs)
            end)
            |> then(fn workflow_acc ->
              Enum.reduce(step_data.internal_specs, workflow_acc, &add_component_spec(&2, &1))
            end)
        end

      attach_output_accumulators(acc, step_data, accumulators, step_id)
    end)
  end

  defp add_step_with_dependencies(
         workflow,
         steps,
         step_data,
         parent_sources,
         dependency_input_assembly
       ) do
    parent_refs = Enum.map(parent_sources, & &1.parent_ref)

    workflow =
      add_component_spec(workflow, step_data.primary_spec, parent_refs)

    {workflow, dependency_parent_refs} =
      resolve_dependency_parent_refs(
        workflow,
        steps,
        step_data.step_id,
        dependency_input_assembly
      )

    Enum.reduce(step_data.internal_specs, workflow, fn spec, workflow_acc ->
      add_component_spec(
        workflow_acc,
        Map.put(spec, :parents, [step_data.primary_name | dependency_parent_refs])
      )
    end)
  end

  defp attach_output_accumulators(workflow, step_data, accumulators, step_id) do
    capture_targets =
      Map.get(step_data, :captured_outputs, [%{step_id: step_id, refs: step_data.capture_refs}])

    Enum.reduce(capture_targets, workflow, fn %{step_id: captured_step_id, refs: refs}, acc ->
      case Map.get(accumulators, captured_step_id) do
        nil ->
          acc

        accumulator ->
          Enum.reduce(refs, acc, fn parent_ref, workflow_acc ->
            Workflow.add(workflow_acc, accumulator, to: parent_ref, validate: :off)
          end)
      end
    end)
  end

  defp add_explicit_join_step(workflow, step_data, parent_sources) do
    {workflow, normalized_refs} =
      normalize_split_join_parent_refs(workflow, step_data, parent_sources)

    add_component(workflow, step_data.component, normalized_refs, :all)
  end

  defp add_implicit_join_aggregator_step(workflow, step_data, parent_sources) do
    {workflow, normalized_refs} =
      normalize_split_join_parent_refs(workflow, step_data, parent_sources)

    workflow
    |> add_component(step_data.join_component, normalized_refs, :all)
    |> Workflow.add(step_data.reduce_component, to: step_data.join_name, validate: :off)
  end

  defp normalize_split_join_parent_refs(workflow, step_data, parent_sources) do
    parent_contexts =
      Map.new(step_data.parent_contexts, fn context -> {context.source_step_id, context} end)

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
    collect_parent_ref_across_lineage(workflow, join_id, parent_ref, lineage, index)
  end

  defp collect_parent_ref_across_lineage(workflow, owner_id, parent_ref, lineage, index) do
    lineage
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce({workflow, parent_ref}, fn {splitter_id, depth_index},
                                              {workflow_acc, current_ref} ->
      {workflow_acc, collected_ref} =
        add_collector_level(
          workflow_acc,
          owner_id,
          current_ref,
          splitter_id,
          index,
          depth_index
        )

      case depth_index do
        0 ->
          {workflow_acc, collected_ref}

        _ ->
          flatten_name = "#{owner_id}__branch__#{index}__level__#{depth_index}__flatten"
          flatten = flatten_collection_layer_step(flatten_name)

          {
            Workflow.add(workflow_acc, flatten, to: collected_ref, validate: :off),
            flatten_name
          }
      end
    end)
  end

  defp add_collector_level(workflow, owner_id, current_ref, splitter_id, index, depth_index) do
    level_name = "#{owner_id}__branch__#{index}__level__#{depth_index}"
    reduce_name = "#{level_name}__collect"
    empty_condition_name = "#{level_name}__empty"
    empty_default_name = "#{level_name}__default"
    output_name = "#{level_name}__collected"
    output_union = passthrough_step(output_name)
    reduce = build_collect_reduce_component(reduce_name, splitter_id)
    empty_condition = build_empty_collection_condition(empty_condition_name)
    empty_default = constant_step(empty_default_name, [])

    workflow =
      workflow
      |> Workflow.add(reduce, to: current_ref, validate: :off)
      |> Workflow.add(empty_condition, to: splitter_extractor_name(splitter_id), validate: :off)
      |> Workflow.add(empty_default, to: empty_condition_name, validate: :off)
      |> add_component(output_union, [{reduce_name, :fan_in}, empty_default_name], :any)

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

  defp build_connection_indexes(connections) do
    Enum.reduce(
      connections,
      %{incoming: %{}, outgoing: %{}, source_step_ids: MapSet.new()},
      fn connection, indexes ->
        %{
          incoming:
            Map.update(
              indexes.incoming,
              connection.target_step_id,
              [connection],
              &[
                connection | &1
              ]
            ),
          outgoing:
            Map.update(
              indexes.outgoing,
              connection.source_step_id,
              [connection],
              &[
                connection | &1
              ]
            ),
          source_step_ids: MapSet.put(indexes.source_step_ids, connection.source_step_id)
        }
      end
    )
  end

  defp planned_flow_connections(%{connection_plan: %{connections: connections}}) do
    connections
    |> Map.values()
    |> Enum.filter(&(&1.kind == :flow))
    |> Enum.sort_by(& &1.order)
  end

  defp indexed_connections(connection_indexes, direction, step_id) do
    connection_indexes
    |> Map.fetch!(direction)
    |> Map.get(step_id, [])
    |> Enum.reverse()
  end

  defp trigger_manifest(steps) do
    steps
    |> Map.values()
    |> Enum.filter(&(&1.step_kind == :trigger))
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn step ->
      %{
        step_id: step.id,
        type_id: step.type_id,
        config: step.config
      }
    end)
  end

  defp result_step_ids(ir, connection_indexes) do
    output_step_ids =
      ir.steps
      |> Map.values()
      |> Enum.filter(&(&1.type_id == "data_output"))
      |> Enum.map(& &1.id)
      |> Enum.sort()

    case output_step_ids do
      [] -> terminal_step_ids(ir, connection_indexes)
      _ -> output_step_ids
    end
  end

  defp terminal_step_ids(ir, connection_indexes) do
    ir.steps
    |> Map.values()
    |> Enum.reject(&MapSet.member?(connection_indexes.source_step_ids, &1.id))
    |> Enum.map(& &1.id)
    |> Enum.sort()
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

  defp resolve_parent_sources(
         workflow,
         steps,
         step_id,
         connection_indexes
       ) do
    step_id
    |> incoming_flow_connections(connection_indexes)
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

  defp resolve_dependency_parent_refs(workflow, steps, target_step_id, dependency_input_assembly) do
    dependency_input_assembly.input_specs
    |> Enum.reduce({workflow, []}, fn input_spec, {workflow_acc, parent_refs} ->
      input_spec.connections
      |> Enum.with_index()
      |> Enum.reduce({workflow_acc, parent_refs}, fn {connection, index},
                                                     {connection_workflow, refs_acc} ->
        source_step = Map.fetch!(steps, connection.source_step_id)

        refs =
          source_step
          |> source_refs_for(connection.source_output)
          |> Enum.uniq()

        case refs do
          [] ->
            raise ArgumentError,
                  "dependency connection from `#{connection.source_step_id}` to `#{target_step_id}` references an unknown output handle"

          [ref] ->
            {connection_workflow, refs_acc ++ [ref]}

          _multiple_refs ->
            {connection_workflow, union_ref} =
              add_dependency_parent_union(
                connection_workflow,
                target_step_id,
                input_spec.id,
                connection.source_step_id,
                index,
                refs
              )

            {connection_workflow, refs_acc ++ [union_ref]}
        end
      end)
    end)
  end

  defp add_dependency_parent_union(
         workflow,
         target_step_id,
         input_id,
         source_step_id,
         index,
         refs
       ) do
    union_name =
      "#{target_step_id}__dependency__#{input_id}__from__#{source_step_id}__#{index}__union"

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

  defp build_steps(steps, accumulators, step_scopes, dependency_input_assemblies) do
    Map.new(steps, fn {step_id, step} ->
      dependency_input_assembly = Map.get(dependency_input_assemblies, step_id)

      {step_id,
       build_step(
         step,
         accumulators,
         Map.get(step_scopes, step_id),
         dependency_input_assembly
       )}
    end)
  end

  defp build_step(step, accumulators, step_scope, dependency_input_assembly) do
    meta_refs =
      step
      |> executor_dependencies()
      |> build_meta_refs(accumulators)

    cond do
      dependency_input_assembly != nil ->
        build_step_with_dependency_inputs(step, meta_refs, dependency_input_assembly)

      step.type_id == "splitter" ->
        build_splitter_step(step, meta_refs)

      step.type_id == "aggregator" ->
        build_aggregator_step(step, meta_refs, step_scope)

      step.type_id == "join" ->
        build_join_step(step, meta_refs, step_scope)

      step.type_id == "condition" ->
        build_condition_step(step, meta_refs)

      step.type_id == "switch" ->
        build_switch_step(step, meta_refs)

      true ->
        build_plain_step(step, meta_refs)
    end
  end

  @credential_runtime_keys [
    :_credential_resolver,
    :current_scope,
    :user_id,
    :project_id,
    :workos_organization_id
  ]

  defp executor_dependencies(%{type_id: "ai_agent", dependencies: dependencies} = step) do
    step
    |> credential_runtime_dependencies(dependencies)
    |> update_runtime_keys([:current_scope])
  end

  defp executor_dependencies(%{dependencies: dependencies} = step) do
    credential_runtime_dependencies(step, dependencies)
  end

  defp credential_runtime_dependencies(step, dependencies) do
    if credential_ref_config?(Map.get(step, :compiled_config)) do
      update_runtime_keys(dependencies, @credential_runtime_keys)
    else
      dependencies
    end
  end

  defp credential_ref_config?(%{"credential_ref" => %AccessPlan.CredentialRef{}}), do: true

  defp credential_ref_config?(%{credential_ref: %AccessPlan.CredentialRef{}}), do: true

  defp credential_ref_config?(%{__struct__: _struct}), do: false

  defp credential_ref_config?(map) when is_map(map) do
    Enum.any?(map, fn {_key, value} -> credential_ref_config?(value) end)
  end

  defp credential_ref_config?(list) when is_list(list),
    do: Enum.any?(list, &credential_ref_config?/1)

  defp credential_ref_config?(_value), do: false

  defp update_runtime_keys(dependencies, runtime_keys) do
    Map.update(dependencies, :runtime_keys, runtime_keys, fn existing_keys ->
      existing_keys
      |> List.wrap()
      |> Kernel.++(runtime_keys)
      |> Enum.uniq()
    end)
  end

  defp build_step_with_dependency_inputs(step, meta_refs, dependency_input_assembly) do
    primary_name = "#{step.id}__primary"
    primary_capture = passthrough_step(primary_name)

    component =
      build_connected_executor_component(step, step.id, meta_refs, dependency_input_assembly)

    %{
      kind: :with_dependencies,
      step_id: step.id,
      primary_name: primary_name,
      entry_specs: [],
      primary_spec: %{component: primary_capture},
      internal_specs: [%{component: component}],
      source_refs: %{"main" => [step.id]},
      capture_refs: [step.id],
      captured_outputs: [%{step_id: step.id, refs: [step.id]}],
      meta_targets: meta_targets(component, meta_refs)
    }
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

    cond do
      step_scope.implicit_aggregator_join? ->
        join_name = "#{step.id}__join"
        join_component = build_fixed_join_component(join_name, "zip_nil")

        reduce_component =
          build_aggregator_reduce_component(
            step.id,
            operation,
            step.compiled_config,
            step.dependencies,
            meta_refs,
            nil
          )

        %{
          kind: :aggregator_join,
          step_id: step.id,
          join_name: join_name,
          join_component: join_component,
          reduce_component: reduce_component,
          parent_contexts: step_scope.parent_contexts,
          join_has_split?: true,
          source_refs: %{"main" => [{step.id, :fan_in}]},
          capture_refs: [{step.id, :fan_in}],
          meta_targets: meta_targets(reduce_component, meta_refs)
        }

      is_binary(mapped_from) ->
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
            operation,
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

      true ->
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
         _compiled_config,
         _dependencies,
         [],
         mapped_from
       ) do
    Runic.reduce(
      AggregatorExecutor.init_for_operation(operation),
      fn item, acc ->
        RuntimeCallbacks.aggregate_reduce(item, acc, ^operation)
      end,
      name: ^name,
      map: ^mapped_from
    )
  end

  defp build_aggregator_reduce_component(
         name,
         operation,
         _compiled_config,
         _dependencies,
         meta_refs,
         mapped_from
       ) do
    Runic.reduce(
      AggregatorExecutor.init_for_operation(operation),
      fn item, acc, meta_ctx ->
        RuntimeCallbacks.aggregate_reduce(item, acc, meta_ctx, ^operation)
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

  defp build_aggregate_empty_component(name, operation, _dependencies, []) do
    Runic.step(
      fn input ->
        RuntimeCallbacks.aggregate_empty_result(input, operation)
      end,
      name: ^name
    )
  end

  defp build_aggregate_empty_component(name, operation, _dependencies, meta_refs) do
    Runic.step(
      fn input, meta_ctx ->
        RuntimeCallbacks.aggregate_empty_result(input, meta_ctx, operation)
      end,
      name: ^name
    )
    |> Map.put(:meta_refs, meta_refs)
  end

  defp build_empty_collection_condition(name) do
    Runic.condition(
      fn input ->
        RuntimeCallbacks.empty_collection?(input)
      end,
      name: ^name
    )
  end

  defp build_fixed_join_component(name, mode) do
    Runic.step(
      fn input ->
        RuntimeCallbacks.execute_join(mode, input)
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

  defp flatten_collection_layer_step(name) do
    Runic.step(
      fn input ->
        RuntimeCallbacks.flatten_collection_layer(input)
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

        RuntimeCallbacks.execute_executor(
          ^executor,
          config,
          input,
          RuntimeCallbacks.executor_context(input, %{}, ^step_context)
        )
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
        resolution_context = RuntimeCallbacks.resolution_context(input, meta_ctx, ^dependencies)
        config = ConfigResolver.resolve_config(^compiled_config, resolution_context)

        RuntimeCallbacks.execute_executor(
          ^executor,
          config,
          input,
          RuntimeCallbacks.executor_context(input, resolution_context, ^step_context)
        )
      end,
      name: ^name
    )
    |> Map.put(:meta_refs, meta_refs)
  end

  defp build_connected_executor_component(step, name, [], dependency_input_assembly) do
    executor = step.executor
    compiled_config = step.compiled_config
    step_context = base_step_context(step)
    input_specs = dependency_input_assembly.input_specs
    parent_count = 1 + dependency_input_assembly.connection_count

    Runic.step(
      fn input ->
        {resolution_input, executor_input} =
          RuntimeCallbacks.assemble_connected_input(input, ^input_specs, ^parent_count)

        config =
          ConfigResolver.resolve_config(^compiled_config, %{
            input: resolution_input,
            steps: %{},
            workflow: %{},
            env: %{}
          })

        RuntimeCallbacks.execute_executor(
          ^executor,
          config,
          executor_input,
          RuntimeCallbacks.executor_context(executor_input, %{}, ^step_context)
        )
      end,
      name: ^name
    )
  end

  defp build_connected_executor_component(step, name, meta_refs, dependency_input_assembly) do
    executor = step.executor
    compiled_config = step.compiled_config
    step_context = base_step_context(step)
    dependencies = step.dependencies
    input_specs = dependency_input_assembly.input_specs
    parent_count = 1 + dependency_input_assembly.connection_count

    Runic.step(
      fn input, meta_ctx ->
        {resolution_input, executor_input} =
          RuntimeCallbacks.assemble_connected_input(input, ^input_specs, ^parent_count)

        resolution_context =
          RuntimeCallbacks.resolution_context(resolution_input, meta_ctx, ^dependencies)

        config = ConfigResolver.resolve_config(^compiled_config, resolution_context)

        RuntimeCallbacks.execute_executor(
          ^executor,
          config,
          executor_input,
          RuntimeCallbacks.executor_context(executor_input, resolution_context, ^step_context)
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
        RuntimeCallbacks.condition_branch_matches(input, compiled_config, executor, branch)
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
        RuntimeCallbacks.condition_branch_matches(
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
        RuntimeCallbacks.switch_branch_matches(input, compiled_config, branch_match)
      end,
      name: ^name
    )
  end

  defp build_switch_condition_component(step, meta_refs, name, branch_match) do
    compiled_config = step.compiled_config
    dependencies = step.dependencies

    Runic.condition(
      fn input, meta_ctx ->
        RuntimeCallbacks.switch_branch_matches(
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
      Enum.map(dependencies.runtime_keys, fn runtime_key ->
        %{
          kind: :context,
          target: runtime_key,
          field_path: [],
          context_key: runtime_key
        }
      end)

    step_refs ++ runtime_refs
  end

  defp compute_dependency_input_assemblies(ir) do
    ir.connection_plan.dependency_inputs_by_target
    |> Enum.reduce(%{}, fn {target_step_id, dependencies}, acc ->
      case dependencies do
        dependencies when dependencies == %{} ->
          acc

        dependencies ->
          step = Map.fetch!(ir.steps, target_step_id)

          input_specs =
            step
            |> ConnectionHandles.input_handles()
            |> Enum.filter(&(&1.kind == :dependency))
            |> Enum.map(fn handle ->
              connection_ids = Map.get(dependencies, handle.id, [])

              connections =
                connection_ids
                |> Enum.map(&Map.fetch!(ir.connection_plan.connections, &1))
                |> Enum.sort_by(& &1.order)

              %{
                id: handle.id,
                input_key: handle.key,
                cardinality: handle.cardinality,
                connection_ids: Enum.map(connections, & &1.id),
                step_ids: Enum.map(connections, & &1.source_step_id),
                connections: connections
              }
            end)

          Map.put(acc, target_step_id, %{
            target_step_id: target_step_id,
            input_specs: input_specs,
            connection_count:
              input_specs
              |> Enum.flat_map(& &1.connection_ids)
              |> length()
          })
      end
    end)
  end

  defp passthrough_step(name) do
    Runic.step(fn input -> input end, name: ^name)
  end

  defp splitter_extractor_name(step_id), do: "#{step_id}__extract"

  defp source_refs_for(%{source_refs: source_refs}, output_handle) do
    Map.get(source_refs, output_handle, [])
  end

  defp incoming_flow_connections(step_id, connection_indexes) do
    connection_indexes
    |> indexed_connections(:incoming, step_id)
    |> Enum.filter(fn connection ->
      connection.target_step_id == step_id
    end)
  end

  defp ordered_connection_groups(connections) do
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

  defp base_step_context(step) do
    %{
      step_id: step.id,
      step_name: step.name,
      type_id: step.type_id,
      retry: Map.get(step, :retry)
    }
  end

  defp put_effective_join_mode(compiled_config, mode) do
    Map.put(compiled_config, "mode", %AccessPlan.Literal{value: mode})
  end

  defp referenced_step_ids(steps) do
    steps
    |> Map.values()
    |> Enum.flat_map(& &1.dependencies.step_ids)
    |> Enum.uniq()
  end
end
