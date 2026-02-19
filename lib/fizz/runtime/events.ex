defmodule Fizz.Runtime.Events do
  @moduledoc """
  Event emission and handling for workflow execution.

  All subscriptions require a valid scope with appropriate permissions.

  Provides a unified interface for emitting execution events that can be
  consumed by:
  - Real-time UI via Phoenix PubSub
  - Logging infrastructure
  - External webhooks
  - Metrics/observability systems

  ## Event Types

  - `:execution_started` - Execution has begun
  - `:execution_completed` - Execution finished successfully
  - `:execution_failed` - Execution failed with error
  - `:step_started` - A step is about to execute
  - `:step_completed` - A step completed successfully
  - `:step_failed` - A step failed
  """

  require Logger

  alias Fizz.Accounts.Scope

  @type event_type ::
          :execution_started
          | :execution_completed
          | :execution_failed
          | :execution_cancelled
          | :step_started
          | :step_completed
          | :step_failed
          | :step_cancelled

  @type event :: %{
          type: event_type(),
          execution_id: String.t(),
          timestamp: DateTime.t(),
          data: map()
        }

  @doc """
  Emits an execution event.

  Events are broadcast via PubSub and logged.
  """
  @spec emit(event_type(), String.t(), map()) :: :ok
  def emit(type, execution_id, data \\ %{}) do
    event = build_event(type, execution_id, data)

    # Log the event
    log_event(event)

    # Broadcast via PubSub
    broadcast(event)

    # Emit telemetry
    emit_telemetry(event)

    :ok
  end

  @doc """
  Subscribes to events for a specific execution.

  Requires a scope with view access to the execution's workflow.
  Returns `:ok` on success, `{:error, :unauthorized}` if access denied,
  or `{:error, :not_found}` if execution doesn't exist.
  """
  @spec subscribe(Scope.t() | nil, String.t()) :: :ok | {:error, :unauthorized | :not_found}
  def subscribe(scope, execution_id) do
    case authorize(scope, execution_id) do
      :ok ->
        Phoenix.PubSub.subscribe(Fizz.PubSub, topic(execution_id))
        :ok

      error ->
        error
    end
  end

  @doc """
  Unsubscribes from events for a specific execution.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(execution_id) do
    Phoenix.PubSub.unsubscribe(Fizz.PubSub, topic(execution_id))
  end

  @doc """
  Checks if the scope can subscribe to execution events.

  Returns `:ok` if authorized, `{:error, :not_found}` if execution doesn't exist,
  or `{:error, :unauthorized}` if access denied.
  """
  @spec authorize(Scope.t() | nil, String.t()) :: :ok | {:error, :unauthorized | :not_found}
  def authorize(scope, execution_id) do
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

  # ===========================================================================
  # Private
  # ===========================================================================

  defp build_event(type, execution_id, data) do
    %{
      type: type,
      execution_id: execution_id,
      timestamp: DateTime.utc_now(),
      data: sanitize_data(data)
    }
  end

  defp topic(execution_id), do: "execution:#{execution_id}"

  defp broadcast(event) do
    if pubsub_available?() do
      Phoenix.PubSub.broadcast(
        Fizz.PubSub,
        topic(event.execution_id),
        {:execution_event, event}
      )
    end
  rescue
    e ->
      Logger.warning("Failed to broadcast event: #{inspect(e)}")
  end

  defp log_event(%{type: type, execution_id: exec_id} = event) do
    level = event_log_level(type)

    if level == :error do
      message = event_message(type)

      Logger.log(level, message,
        type: type,
        execution_id: exec_id,
        data: Map.get(event, :data, %{})
      )
    end
  end

  defp emit_telemetry(%{type: type, execution_id: exec_id, data: data}) do
    event_name = [:fizz, :execution, :event]

    :telemetry.execute(
      event_name,
      %{system_time: System.system_time()},
      %{type: type, execution_id: exec_id, data: data}
    )
  end

  defp event_log_level(:execution_failed), do: :error
  defp event_log_level(:step_failed), do: :error
  defp event_log_level(_), do: :info

  defp event_message(:execution_started), do: "Execution started"
  defp event_message(:execution_completed), do: "Execution completed"
  defp event_message(:execution_cancelled), do: "Execution cancelled"
  defp event_message(:execution_failed), do: "Execution failed"
  defp event_message(:step_started), do: "Step started"
  defp event_message(:step_completed), do: "Step completed"
  defp event_message(:step_failed), do: "Step failed"
  defp event_message(:step_cancelled), do: "Step cancelled"
  defp event_message(type), do: "Event: #{type}"

  defp sanitize_data(data) when is_map(data) do
    Fizz.Runtime.Serializer.sanitize(data)
  rescue
    _ -> %{error: "Failed to sanitize data"}
  end

  defp sanitize_data(data), do: %{value: inspect(data)}

  defp pubsub_available? do
    !!Process.whereis(Fizz.PubSub)
  end
end
