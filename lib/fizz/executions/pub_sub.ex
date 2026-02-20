defmodule Fizz.Executions.PubSub do
  @moduledoc """
  PubSub topic and authorization helpers for execution updates.

  Canonical event payloads are emitted through `Fizz.Executions.Events`.
  """

  alias Fizz.Accounts.Scope
  alias Fizz.Executions.Events

  @pubsub Fizz.PubSub

  @step_lifecycle_events [
    :step_started,
    :step_completed,
    :step_failed,
    :step_skipped,
    :step_cancelled
  ]

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
    case Fizz.Repo.get(Fizz.Executions.Execution, execution_id) do
      nil ->
        {:error, :not_found}

      execution ->
        execution = Fizz.Repo.preload(execution, :workflow)

        if Scope.can_view_execution?(scope, execution) do
          :ok
        else
          {:error, :unauthorized}
        end
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
    case Fizz.Repo.get(Fizz.Workflows.Workflow, workflow_id) do
      nil ->
        {:error, :not_found}

      workflow ->
        if Scope.can_view_workflow?(scope, workflow) do
          :ok
        else
          {:error, :unauthorized}
        end
    end
  end

  # ============================================================================
  # Runtime Step Broadcasts
  # ============================================================================

  @doc """
  Broadcasts a step lifecycle event using the canonical execution event envelope.
  """
  @spec broadcast_step(atom(), String.t(), String.t() | nil, map()) :: :ok
  def broadcast_step(event_name, execution_id, workflow_id, payload)
      when event_name in @step_lifecycle_events and is_binary(execution_id) and is_map(payload) do
    Events.emit(
      event_name,
      execution_id,
      payload,
      workflow_id: workflow_id,
      source: :runtime_step
    )
  end
end
