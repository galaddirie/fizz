defmodule Fizz.Workflows.Compiler.RuntimeCallbacks do
  @moduledoc false

  alias Fizz.Integrations.Library.Fizz.Builtins.Aggregator, as: AggregatorExecutor
  alias Fizz.Integrations.Library.Fizz.Builtins.Join, as: JoinExecutor
  alias Fizz.Integrations.Library.Fizz.Builtins.Switch, as: SwitchExecutor
  alias Fizz.Workflows.ExecutionContext
  alias Fizz.Workflows.Runtime.ConfigResolver
  alias Fizz.Workflows.StepExecutionError

  @doc false
  def resolution_context(input, meta_ctx, dependencies) do
    workflow = Map.get(meta_ctx, :workflow) || %{}
    metadata = Map.get(meta_ctx, :metadata) || %{}
    execution_context = ExecutionContext.from_map(Map.put(meta_ctx, :input, input))

    %{
      input: input,
      steps:
        dependencies.step_ids
        |> Enum.reduce(%{}, fn step_id, acc ->
          Map.put(acc, step_id, Map.get(meta_ctx, {:step_output, step_id}))
        end),
      workflow: workflow,
      env: Map.get(meta_ctx, :env) || %{},
      metadata: metadata,
      scope: execution_context.scope,
      current_scope: execution_context.scope,
      user_id: runtime_context_value(meta_ctx, workflow, metadata, :user_id),
      project_id: runtime_context_value(meta_ctx, workflow, metadata, :project_id),
      workos_organization_id:
        runtime_context_value(meta_ctx, workflow, metadata, :workos_organization_id),
      _credential_resolver: Map.get(meta_ctx, :_credential_resolver),
      execution_context: execution_context
    }
  end

  @doc false
  def executor_context(input, resolution_context, step_context) do
    step_context
    |> Map.merge(%{
      input: input,
      steps: Map.get(resolution_context, :steps, %{}),
      workflow: Map.get(resolution_context, :workflow, %{}),
      env: Map.get(resolution_context, :env, %{}),
      metadata: Map.get(resolution_context, :metadata, %{}),
      scope: Map.get(resolution_context, :scope),
      current_scope: Map.get(resolution_context, :current_scope),
      user_id: Map.get(resolution_context, :user_id),
      project_id: Map.get(resolution_context, :project_id),
      workos_organization_id: Map.get(resolution_context, :workos_organization_id),
      _credential_resolver: Map.get(resolution_context, :_credential_resolver)
    })
    |> ExecutionContext.put_legacy_aliases()
  end

  @doc false
  def execute_executor(executor, config, input, context) do
    case executor.execute(config, input, context) do
      {:ok, output} -> output
      {:skip, reason} -> {:skip, reason}
      {:error, reason} -> raise step_execution_error(reason, context)
      other -> other
    end
  end

  @doc false
  def switch_branch_matches(input, compiled_config, branch_match) do
    resolution_context = %{
      input: input,
      steps: %{},
      workflow: %{},
      env: %{}
    }

    branch_match?(matched_switch_branch(compiled_config, resolution_context), branch_match)
  end

  @doc false
  def switch_branch_matches(input, meta_ctx, compiled_config, dependencies, branch_match) do
    resolution_context = resolution_context(input, meta_ctx, dependencies)

    branch_match?(matched_switch_branch(compiled_config, resolution_context), branch_match)
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
  def assemble_connected_input(input, input_specs, 1) do
    {input, build_connected_executor_input(input, input_specs, [])}
  end

  def assemble_connected_input([primary | dependency_values], input_specs, parent_count)
      when is_list(input_specs) and parent_count > 1 do
    {primary, build_connected_executor_input(primary, input_specs, dependency_values)}
  end

  def assemble_connected_input(input, input_specs, _parent_count) do
    {input, build_connected_executor_input(input, input_specs, [])}
  end

  def assemble_root_input(input, input_specs, parent_count) do
    assemble_connected_input(input, input_specs, parent_count)
  end

  @doc false
  def aggregate_reduce(item, acc, operation) do
    operation = normalize_aggregator_operation(operation)
    AggregatorExecutor.reducer_for_operation(operation).(item, acc)
  end

  @doc false
  def aggregate_reduce(item, acc, _meta_ctx, operation) do
    operation = normalize_aggregator_operation(operation)
    AggregatorExecutor.reducer_for_operation(operation).(item, acc)
  end

  @doc false
  def aggregate_empty_result(_input, operation) do
    operation
    |> normalize_aggregator_operation()
    |> AggregatorExecutor.init_for_operation()
  end

  @doc false
  def aggregate_empty_result(_input, _meta_ctx, operation) do
    operation
    |> normalize_aggregator_operation()
    |> AggregatorExecutor.init_for_operation()
  end

  @doc false
  def execute_join(mode, input) do
    {:ok, output} = JoinExecutor.execute(%{"mode" => mode, "flatten" => false}, input, %{})
    output
  end

  @doc false
  def flatten_collection_layer(input) when is_list(input) do
    Enum.flat_map(input, fn
      item when is_list(item) -> item
      item -> [item]
    end)
  end

  def flatten_collection_layer(input), do: input

  @doc false
  def empty_collection?(input) when is_list(input), do: input == []
  def empty_collection?(input) when is_map(input), do: map_size(input) == 0
  def empty_collection?(%Range{} = input), do: Enum.empty?(input)
  def empty_collection?(nil), do: true
  def empty_collection?(_input), do: false

  defp runtime_context_value(meta_ctx, workflow, metadata, key) do
    Map.get(meta_ctx, key) || Map.get(workflow, key) || Map.get(metadata, key)
  end

  defp step_execution_error(reason, context) do
    StepExecutionError.exception(
      reason: reason,
      step_id: Map.get(context, :step_id),
      step_type_id: Map.get(context, :type_id),
      retry: Map.get(context, :retry)
    )
  end

  defp matched_switch_branch(compiled_config, resolution_context) do
    value =
      compiled_config
      |> Map.get("value")
      |> ConfigResolver.resolve_value(resolution_context)

    cases =
      compiled_config
      |> Map.get("cases", [])
      |> Enum.map(&resolve_switch_case(&1, resolution_context))

    SwitchExecutor.matched_branch(value, cases)
  end

  defp branch_match?(matched_branch, expected_branch), do: matched_branch == expected_branch

  defp resolve_switch_case(case_def, resolution_context) when is_map(case_def) do
    Map.update(case_def, "match", nil, &ConfigResolver.resolve_value(&1, resolution_context))
  end

  defp normalize_aggregator_operation(operation) when is_binary(operation), do: operation
  defp normalize_aggregator_operation(_operation), do: "collect"

  defp build_connected_executor_input(primary, input_specs, dependency_values) do
    {assembled_input, remaining_values} =
      Enum.reduce(input_specs, {%{"main" => primary}, dependency_values}, fn input_spec,
                                                                             {assembled, values} ->
        {dependency_value, remaining} = take_dependency_value(input_spec, values)
        {Map.put(assembled, input_spec.input_key, dependency_value), remaining}
      end)

    case remaining_values do
      [] -> assembled_input
      _ -> raise ArgumentError, "unexpected extra dependency values for connected executor input"
    end
  end

  defp take_dependency_value(%{cardinality: :many, step_ids: step_ids}, values) do
    Enum.split(values, length(step_ids))
  end

  defp take_dependency_value(%{cardinality: :one, step_ids: []}, values), do: {nil, values}

  defp take_dependency_value(%{cardinality: :one, step_ids: [_step_id]}, [value | rest]),
    do: {value, rest}

  defp take_dependency_value(%{cardinality: :one, step_ids: [_step_id]}, []) do
    {nil, []}
  end
end
