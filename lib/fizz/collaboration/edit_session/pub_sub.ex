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
  - `{:sync_state, state}` - Full state sync for reconnection
  - `{:webhook_test_execution, %{execution_id: execution_id}}` - Test webhook execution created

  Presence:
  - `{:presence_diff, diff}` - Phoenix.Presence diff
  - `{:lock_acquired, step_id, user_id}` - Step lock acquired
  - `{:lock_released, step_id}` - Step lock released
  """

  alias Fizz.Accounts.Scope

  @pubsub Fizz.PubSub

  # Topic builders

  def session_topic(workflow_id), do: "edit_session:#{workflow_id}"
  def presence_topic(workflow_id), do: "edit_presence:#{workflow_id}"

  # ============================================================================
  # Subscriptions (Scope Required)
  # ============================================================================

  @doc """
  Subscribe to edit session updates for a workflow.

  Requires a scope with edit access to the workflow.
  Returns `:ok` on success, `{:error, :unauthorized}` if access denied,
  or `{:error, :not_found}` if workflow doesn't exist.
  """
  @spec subscribe_session(Scope.t() | nil, String.t()) ::
          :ok | {:error, :unauthorized | :not_found}
  def subscribe_session(scope, workflow_id) do
    case authorize_edit(scope, workflow_id) do
      :ok ->
        Phoenix.PubSub.subscribe(@pubsub, session_topic(workflow_id))
        :ok

      error ->
        error
    end
  end

  @doc """
  Unsubscribe from edit session updates.
  """
  @spec unsubscribe_session(String.t()) :: :ok
  def unsubscribe_session(workflow_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, session_topic(workflow_id))
  end

  @doc """
  Subscribe to presence updates for a workflow's edit session.

  Requires a scope with edit access to the workflow.
  Returns `:ok` on success, `{:error, :unauthorized}` if access denied,
  or `{:error, :not_found}` if workflow doesn't exist.
  """
  @spec subscribe_presence(Scope.t() | nil, String.t()) ::
          :ok | {:error, :unauthorized | :not_found}
  def subscribe_presence(scope, workflow_id) do
    case authorize_edit(scope, workflow_id) do
      :ok ->
        Phoenix.PubSub.subscribe(@pubsub, presence_topic(workflow_id))
        :ok

      error ->
        error
    end
  end

  @doc """
  Unsubscribe from presence updates.
  """
  @spec unsubscribe_presence(String.t()) :: :ok
  def unsubscribe_presence(workflow_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, presence_topic(workflow_id))
  end

  @doc """
  Subscribe to both session and presence updates.

  Convenience function that subscribes to both topics.
  Returns `:ok` on success, or error tuple if authorization fails.
  """
  @spec subscribe_all(Scope.t() | nil, String.t()) ::
          :ok | {:error, :unauthorized | :not_found}
  def subscribe_all(scope, workflow_id) do
    case authorize_edit(scope, workflow_id) do
      :ok ->
        Phoenix.PubSub.subscribe(@pubsub, session_topic(workflow_id))
        Phoenix.PubSub.subscribe(@pubsub, presence_topic(workflow_id))
        :ok

      error ->
        error
    end
  end

  @doc """
  Unsubscribe from both session and presence updates.
  """
  @spec unsubscribe_all(String.t()) :: :ok
  def unsubscribe_all(workflow_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, session_topic(workflow_id))
    Phoenix.PubSub.unsubscribe(@pubsub, presence_topic(workflow_id))
  end

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

  @doc """
  Checks if the scope can view edit session (for read-only observation).

  Some use cases may want to allow viewers to observe edits without
  participating. This requires only view access.
  """
  @spec authorize_view(Scope.t() | nil, String.t()) ::
          :ok | {:error, :unauthorized | :not_found}
  def authorize_view(scope, workflow_id) do
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
  Broadcast a full state sync to all session subscribers.
  """
  @spec broadcast_sync(String.t(), map()) :: :ok
  def broadcast_sync(workflow_id, state) do
    Phoenix.PubSub.broadcast(@pubsub, session_topic(workflow_id), {:sync_state, state})
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
