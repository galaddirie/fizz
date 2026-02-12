defmodule Fizz.Executions.PubSub do
  @moduledoc """
  PubSub broadcasting for workflow execution and step execution updates.

  All subscriptions require a valid scope with appropriate permissions.
  This ensures users can only receive updates for resources they have access to.

  ## Topics

  - `execution:{id}` - Updates for a specific execution
  - `workflow_executions:{workflow_id}` - All executions for a workflow

  ## Events

  Execution lifecycle:
  - `{:execution_started, execution}`
  - `{:execution_updated, execution}`
  - `{:execution_completed, execution}`
  - `{:execution_failed, execution, error}`

  Step lifecycle:
  - `{:step_started, step_payload}`
  - `{:step_completed, step_payload}`
  - `{:step_failed, step_payload}`
  """

  import Ecto.Query

  alias Fizz.Executions.{Execution, StepExecution}
  alias Fizz.Accounts.Scope
  alias Fizz.Repo
  alias Fizz.Workflows.Workflow

  @pubsub Fizz.PubSub

  # Topic builders

  def execution_topic(execution_id), do: "execution:#{execution_id}"
  def workflow_executions_topic(workflow_id), do: "workflow_executions:#{workflow_id}"

  # ============================================================================
  # Subscriptions (Scope Required)
  # ============================================================================

  @doc """
  Subscribe to updates for a specific execution.

  Requires a scope with view access to the execution's workflow.
  Returns `:ok` on success, `{:error, :unauthorized}` if access denied,
  or `{:error, :not_found}` if execution doesn't exist.
  """
  @spec subscribe_execution(Scope.t() | nil, String.t()) ::
          :ok | {:error, :unauthorized | :not_found}
  def subscribe_execution(scope, execution_id) do
    case authorize_execution(scope, execution_id) do
      :ok ->
        Phoenix.PubSub.subscribe(@pubsub, execution_topic(execution_id))
        :ok

      error ->
        error
    end
  end

  @doc """
  Unsubscribe from a specific execution's updates.
  """
  @spec unsubscribe_execution(String.t()) :: :ok
  def unsubscribe_execution(execution_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, execution_topic(execution_id))
  end

  @doc """
  Subscribe to all execution updates for a workflow.

  Requires a scope with view access to the workflow.
  Returns `:ok` on success, `{:error, :unauthorized}` if access denied,
  or `{:error, :not_found}` if workflow doesn't exist.
  """
  @spec subscribe_workflow_executions(Scope.t() | nil, String.t()) ::
          :ok | {:error, :unauthorized | :not_found}
  def subscribe_workflow_executions(scope, workflow_id) do
    case authorize_workflow(scope, workflow_id) do
      :ok ->
        Phoenix.PubSub.subscribe(@pubsub, workflow_executions_topic(workflow_id))
        :ok

      error ->
        error
    end
  end

  @doc """
  Unsubscribe from a workflow's execution updates.
  """
  @spec unsubscribe_workflow_executions(String.t()) :: :ok
  def unsubscribe_workflow_executions(workflow_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, workflow_executions_topic(workflow_id))
  end

  # ============================================================================
  # Authorization
  # ============================================================================

  @doc """
  Checks if the scope can subscribe to updates for a specific execution.

  Returns `:ok` if authorized, `{:error, :not_found}` if execution doesn't exist,
  or `{:error, :unauthorized}` if access denied.
  """
  @spec authorize_execution(Scope.t() | nil, String.t()) ::
          :ok | {:error, :unauthorized | :not_found}
  def authorize_execution(scope, execution_id) do
    execution_exists? =
      Repo.exists?(from e in Execution, where: e.id == ^execution_id)

    cond do
      not execution_exists? ->
        {:error, :not_found}

      Repo.exists?(
        Scope.scope_executions(scope, Execution, permission: :view)
        |> where([e], e.id == ^execution_id)
      ) ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Checks if the scope can subscribe to execution updates for a workflow.

  Returns `:ok` if authorized, `{:error, :not_found}` if workflow doesn't exist,
  or `{:error, :unauthorized}` if access denied.
  """
  @spec authorize_workflow(Scope.t() | nil, String.t()) ::
          :ok | {:error, :unauthorized | :not_found}
  def authorize_workflow(scope, workflow_id) do
    workflow_exists? =
      Repo.exists?(from w in Workflow, where: w.id == ^workflow_id)

    cond do
      not workflow_exists? ->
        {:error, :not_found}

      Repo.exists?(
        Scope.scope_workflows(scope, Workflow, permission: :view)
        |> where([w], w.id == ^workflow_id)
      ) ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Deprecated: Use `authorize_execution/2` instead.
  """
  @deprecated "Use authorize_execution/2 instead"
  @spec can_subscribe_execution?(Scope.t() | nil, String.t()) :: boolean()
  def can_subscribe_execution?(scope, execution_id) do
    authorize_execution(scope, execution_id) == :ok
  end

  @doc """
  Deprecated: Use `authorize_workflow/2` instead.
  """
  @deprecated "Use authorize_workflow/2 instead"
  @spec can_subscribe_workflow_executions?(Scope.t() | nil, String.t()) :: boolean()
  def can_subscribe_workflow_executions?(scope, workflow_id) do
    authorize_workflow(scope, workflow_id) == :ok
  end

  # ============================================================================
  # Execution lifecycle broadcasts
  # ============================================================================

  @doc "Broadcast that an execution has started."
  def broadcast_execution_started(%Execution{} = execution) do
    broadcast_execution(:execution_started, execution)
  end

  @doc "Broadcast that an execution has been updated."
  def broadcast_execution_updated(%Execution{} = execution) do
    broadcast_execution(:execution_updated, execution)
  end

  @doc "Broadcast that an execution completed successfully."
  def broadcast_execution_completed(%Execution{} = execution) do
    broadcast_execution(:execution_completed, execution)
  end

  @doc "Broadcast that an execution has been cancelled."
  def broadcast_execution_cancelled(%Execution{} = execution) do
    broadcast_execution(:execution_cancelled, execution)
  end

  @doc "Broadcast that an execution failed."
  def broadcast_execution_failed(%Execution{} = execution, error \\ nil) do
    error = error || execution.error
    message = {:execution_failed, execution, error}

    broadcast(execution.id, message)
    broadcast_workflow(execution.workflow_id, message)
  end

  # ============================================================================
  # Step execution broadcasts
  # ============================================================================

  @doc "Broadcast that a step has started executing."
  def broadcast_step_started(%Execution{} = execution, %StepExecution{} = step_execution) do
    payload = build_step_payload(step_execution)
    broadcast_step(:step_started, execution.id, execution.workflow_id, payload)
  end

  @doc "Broadcast that a step completed successfully."
  def broadcast_step_completed(%Execution{} = execution, %StepExecution{} = step_execution) do
    payload = build_step_payload(step_execution)
    broadcast_step(:step_completed, execution.id, execution.workflow_id, payload)
  end

  @doc "Broadcast that a step failed."
  def broadcast_step_failed(
        %Execution{} = execution,
        %StepExecution{} = step_execution,
        error \\ nil
      ) do
    payload =
      step_execution
      |> build_step_payload()
      |> Map.put(:error, error || step_execution.error)

    broadcast_step(:step_failed, execution.id, execution.workflow_id, payload)
  end

  @doc "Broadcast a step event with a raw payload."
  def broadcast_step(event, execution_id, workflow_id, payload) do
    message = {event, payload}
    broadcast(execution_id, message)
    broadcast_workflow(workflow_id, message)
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp broadcast_execution(event, %Execution{} = execution) do
    message = {event, execution}

    broadcast(execution.id, message)
    broadcast_workflow(execution.workflow_id, message)
  end

  defp build_step_payload(%StepExecution{} = se) do
    %{
      id: se.id,
      execution_id: se.execution_id,
      step_id: se.step_id,
      step_type_id: se.step_type_id,
      status: se.status,
      attempt: se.attempt,
      input_data: se.input_data,
      output_data: se.output_data,
      output_item_count: se.output_item_count,
      item_index: se.item_index,
      items_total: se.items_total,
      error: se.error,
      queued_at: se.queued_at,
      started_at: se.started_at,
      completed_at: se.completed_at,
      duration_us: StepExecution.duration_us(se),
      queue_time_us: StepExecution.queue_time_us(se)
    }
  end

  defp build_step_payload(step_data) when is_map(step_data), do: step_data

  defp broadcast(execution_id, message) do
    Phoenix.PubSub.broadcast(@pubsub, execution_topic(execution_id), message)
  end

  defp broadcast_workflow(workflow_id, message) do
    if workflow_id do
      Phoenix.PubSub.broadcast(@pubsub, workflow_executions_topic(workflow_id), message)
    end
  end
end
