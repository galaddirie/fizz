defmodule Fizz.Collaboration.EditSession.PubSub do
  @moduledoc """
  PubSub for collaborative editing sessions.

  All subscriptions require a valid scope with appropriate permissions.
  Edit sessions require edit access (not just view access) since they
  involve modifying workflow state.

  ## Topics

  - `edit_session:{workflow_id}` - Operations and state changes
  - `edit_presence:{workflow_id}` - User presence updates (cursors, selections)

  ## Events

  Operations:
  - `{:operation_applied, operation}` - An edit operation was applied
  - `{:webhook_test_execution, %{execution_id: execution_id}}` - Test webhook execution created

  Presence:
  - `%Phoenix.Socket.Broadcast{event: "presence_diff", ...}` - Phoenix.Presence diff
  - `{:lock_acquired, step_id, user_id}` - Step lock acquired
  - `{:lock_released, step_id}` - Step lock released
  """

  alias Fizz.Accounts.Scope

  @pubsub Fizz.PubSub

  # Topic builders

  def session_topic(workflow_id), do: "edit_session:#{workflow_id}"
  def presence_topic(workflow_id), do: "edit_presence:#{workflow_id}"

  # ============================================================================
  # Authorization
  # ============================================================================

  @doc """
  Checks if the scope can subscribe to edit session updates.

  Edit sessions require edit access (not just view access) since they
  involve real-time collaboration on workflow modifications.

  Returns `:ok` if authorized, `{:error, :not_found}` if workflow doesn't exist,
  or `{:error, :unauthorized}` if access denied.
  """
  @spec authorize_edit(Scope.t() | nil, String.t()) ::
          :ok | {:error, :unauthorized | :not_found}
  def authorize_edit(nil, _workflow_id), do: {:error, :unauthorized}

  def authorize_edit(%Scope{} = scope, workflow_id) do
    case Fizz.Repo.get(Fizz.Workflows.Workflow, workflow_id) do
      nil ->
        {:error, :not_found}

      workflow ->
        if Scope.can_edit_workflow?(scope, workflow) do
          :ok
        else
          {:error, :unauthorized}
        end
    end
  end

  # ============================================================================
  # Broadcasting
  # ============================================================================

  @doc """
  Broadcast an operation to all session subscribers.
  """
  @spec broadcast_operation(String.t(), term()) :: :ok
  def broadcast_operation(workflow_id, operation) do
    Phoenix.PubSub.broadcast(@pubsub, session_topic(workflow_id), {:operation_applied, operation})
  end

  @doc """
  Broadcast a lock acquisition to all session subscribers.
  """
  @spec broadcast_lock_acquired(String.t(), String.t(), String.t()) :: :ok
  def broadcast_lock_acquired(workflow_id, step_id, user_id) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      session_topic(workflow_id),
      {:lock_acquired, step_id, user_id}
    )
  end

  @doc """
  Broadcast a lock release to all session subscribers.
  """
  @spec broadcast_lock_released(String.t(), String.t()) :: :ok
  def broadcast_lock_released(workflow_id, step_id) do
    Phoenix.PubSub.broadcast(@pubsub, session_topic(workflow_id), {:lock_released, step_id})
  end

  @doc """
  Broadcast an updated editor state to all session subscribers.
  """
  @spec broadcast_editor_state_updated(String.t(), term()) :: :ok
  def broadcast_editor_state_updated(workflow_id, editor_state) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      session_topic(workflow_id),
      {:editor_state_updated, editor_state}
    )
  end

  @doc """
  Broadcast that a test webhook execution was created.
  """
  @spec broadcast_webhook_test_execution(String.t(), String.t()) :: :ok
  def broadcast_webhook_test_execution(workflow_id, execution_id) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      session_topic(workflow_id),
      {:webhook_test_execution, %{execution_id: execution_id}}
    )
  end
end
