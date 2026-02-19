defmodule Fizz.Runtime.Steps.StepRunner do
  @moduledoc """
  Creates Runic Steps from Fizz workflow steps.

  This module bridges Fizz's step system with Runic's step-based execution.
  It handles:
  - Expression evaluation in step configs before execution
  - Building execution context from Runic workflow state
  - Error handling with controlled throws for proper error propagation

  ## Usage

      step = %Fizz.Workflows.Embeds.Step{id: "step_1", type_id: "debug", config: %{}}
      step = StepRunner.create(step, execution_id: "exec_123")

      # The step can then be added to a Runic workflow
      Workflow.add(workflow, step)
  """

  require Runic
  alias Fizz.Runtime.ExecutionContext
  alias Fizz.Runtime.Expression
  alias Fizz.Steps.Executors.Behaviour, as: ExecutorBehaviour

  @type workflow_step :: Fizz.Workflows.Embeds.Step.t()
  @type step_opts :: [
          execution_id: String.t(),
          workflow_id: String.t(),
          variables: map(),
          metadata: map(),
          step_outputs: map(),
          slot_bindings: map(),
          primary_parent_lookup: map(),
          trigger_data: map(),
          trigger_type: atom(),
          current_group: map(),
          all_groups: [map()]
        ]

  @doc """
  Creates a Runic step from an Fizz step.

  The step wraps the step's executor and handles:
  - Building context from the Runic fact input
  - Evaluating expressions in the step's config
  - Executing the step via its registered executor
  - Error handling with controlled throws

  ## Options

  - `:execution_id` - The Fizz Execution record ID
  - `:workflow_id` - The source workflow ID
  - `:variables` - Workflow-level variables for expression evaluation
  - `:metadata` - Execution metadata
  """
  @spec create(workflow_step(), step_opts()) :: Runic.Workflow.Step.t()
  def create(step, opts \\ []) do
    runic_step =
      Runic.step(
        fn input -> execute_step(step, input, opts) end,
        name: runic_name(step)
      )

    # Ensure unique hash for programmatic steps to avoid graph vertex collisions
    # We use phash2 on the combination of the original hash and the step id
    unique_hash = :erlang.phash2({runic_step.hash, step.id}, 4_294_967_296)
    %{runic_step | hash: unique_hash}
  end

  defp execute_step(step, input, opts) do
    case run_step(step, input, opts) do
      {:ok, result} ->
        result

      {:error, {:throw, reason}} ->
        throw(reason)

      {:error, reason} ->
        throw({:step_error, step.id, {:execution_error, reason}})
    end
  end

  defp run_step(step, input, opts) do
    try do
      {:ok, execute_with_context(step, input, opts)}
    rescue
      e ->
        {:error, e}
    catch
      kind, reason ->
        {:error, {kind, reason}}
    end
  end

  # Mapping of trigger step types to their corresponding trigger_type atoms
  @trigger_type_mapping %{
    "manual_input" => :manual,
    "webhook_trigger" => :webhook,
    "schedule_trigger" => :schedule,
    "event_trigger" => :event
  }

  @doc """
  Executes a step with full context building and expression evaluation.

  This is the core execution logic that:
  1. Builds an ExecutionContext from the input
  2. Evaluates expressions in the step's config
  3. Calls the step's executor
  4. Handles errors appropriately
  """
  @spec execute_with_context(workflow_step(), term(), step_opts()) :: term()
  def execute_with_context(step, input, opts) do
    # Build context from options and input
    ctx = build_context(step, input, opts)
    executor_input = build_executor_input(step, ctx.input, ctx.step_outputs, opts)

    # Check if this is a non-active trigger that should be skipped
    if should_skip_trigger?(step.type_id, ctx.trigger_type) do
      Process.put(:fizz_step_skipped, true)
      # Return nil to avoid propagating input from skipped triggers (prevents duplicates in joins)
      nil
    else
      do_execute(step, executor_input, ctx)
    end
  end

  defp should_skip_trigger?(step_type_id, current_trigger_type) do
    case Map.get(@trigger_type_mapping, step_type_id) do
      # Not a trigger step, don't skip
      nil -> false
      expected_type -> expected_type != current_trigger_type
    end
  end

  defp do_execute(step, input, ctx) do
    evaluated_config =
      case evaluate_config(step.config, ctx) do
        {:ok, config} ->
          if ctx.execution_id do
            Task.start(fn ->
              Fizz.Executions.update_step_execution_metadata(ctx.execution_id, ctx.step_id, %{
                "evaluated_config" => config
              })
            end)
          end

          config

        {:error, reason} ->
          throw({:step_error, step.id, {:expression_error, reason}})
      end

    # Resolve and execute the step
    executor = ExecutorBehaviour.resolve!(step.type_id)

    case executor.execute(evaluated_config, input, ctx) do
      {:ok, result} ->
        result

      {:error, reason} ->
        throw({:step_error, step.id, reason})

      {:skip, _reason} ->
        # Signal observability hook that this step was skipped
        Process.put(:fizz_step_skipped, true)
        # Skip produces nil, which Runic will handle appropriately
        nil
    end
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp build_context(step, input, opts) do
    # Get pinned outputs from opts (static, from workflow start)
    pinned_outputs = Keyword.get(opts, :step_outputs, %{})

    # Get dynamic outputs from process dictionary (set by before_step_context hook)
    # This contains outputs from steps that completed earlier in this execution
    dynamic_outputs = Process.get(:fizz_step_outputs, %{})

    # Merge: dynamic outputs take precedence (they're fresh), then pinned
    step_outputs =
      pinned_outputs
      |> Map.merge(dynamic_outputs)
      |> maybe_filter_group_outputs(opts)

    # Filter outputs to only include upstream steps
    upstream_ids = Map.get(Keyword.get(opts, :upstream_lookup, %{}), step.id, [])

    step_outputs =
      Map.take(step_outputs, upstream_ids)

    primary_input = build_primary_input(step, input, step_outputs, opts)

    ExecutionContext.new(
      execution_id: Keyword.get(opts, :execution_id),
      workflow_id: Keyword.get(opts, :workflow_id),
      step_id: step.id,
      variables: Keyword.get(opts, :variables, %{}),
      metadata: Keyword.get(opts, :metadata, %{}),
      input: primary_input,
      step_outputs: step_outputs,
      trigger: Keyword.get(opts, :trigger_data, %{}),
      trigger_type: Keyword.get(opts, :trigger_type)
    )
  end

  defp build_primary_input(step, input, step_outputs, opts) do
    primary_parents =
      opts
      |> Keyword.get(:primary_parent_lookup, %{})
      |> Map.get(step.id, [])

    slot_bindings =
      opts
      |> Keyword.get(:slot_bindings, %{})
      |> Map.get(step.id, %{})

    case primary_parents do
      [] ->
        if slot_bindings == %{} do
          input
        else
          nil
        end

      [parent_step_id] ->
        Map.get(step_outputs, parent_step_id, input)

      _multiple_parents ->
        # Keep existing semantics for fan-in joins and multi-parent inputs.
        input
    end
  end

  defp build_executor_input(step, primary_input, step_outputs, opts) do
    case subnode_slots_for_step(step.type_id) do
      [] ->
        primary_input

      slot_defs ->
        slot_bindings =
          opts
          |> Keyword.get(:slot_bindings, %{})
          |> Map.get(step.id, %{})

        Enum.reduce(slot_defs, %{"_primary" => primary_input}, fn slot_def, acc ->
          slot_id = slot_field(slot_def, :id)
          input_key = slot_field(slot_def, :input_key) || slot_id
          cardinality = slot_field(slot_def, :cardinality) || "one"
          source_step_ids = Map.get(slot_bindings, slot_id, [])

          slot_value =
            source_step_ids
            |> Enum.map(&Map.get(step_outputs, &1))
            |> slot_value_for_cardinality(cardinality)

          Map.put(acc, input_key, slot_value)
        end)
    end
  end

  defp slot_value_for_cardinality(values, "many"), do: values
  defp slot_value_for_cardinality(values, _cardinality), do: List.first(values)

  defp subnode_slots_for_step(type_id) when is_binary(type_id) do
    case Fizz.Steps.Registry.get(type_id) do
      {:ok, type} when is_list(type.subnode_slots) ->
        type.subnode_slots

      _ ->
        []
    end
  end

  defp slot_field(slot, key) when is_map(slot) and is_atom(key) do
    Map.get(slot, key) || Map.get(slot, Atom.to_string(key))
  end

  defp maybe_filter_group_outputs(step_outputs, opts) do
    case Keyword.get(opts, :current_group) do
      nil ->
        groups = Keyword.get(opts, :all_groups, [])

        hidden_step_ids =
          groups
          |> Enum.flat_map(& &1.step_ids)
          |> MapSet.new()

        Map.reject(step_outputs, fn {step_id, _} ->
          MapSet.member?(hidden_step_ids, step_id)
        end)

      _group ->
        step_outputs
    end
  end

  defp evaluate_config(config, ctx) when is_map(config) do
    # Build variables for expression evaluation
    vars = Expression.Context.build_from_context(ctx)

    Expression.evaluate_deep(config, vars)
  end

  defp evaluate_config(config, _ctx), do: {:ok, config}

  # Step ID is now used directly as Runic name
  defp runic_name(%{id: id}) when is_binary(id) and byte_size(id) > 0, do: id
  defp runic_name(_), do: "step"
end
