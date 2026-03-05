defmodule Fizz.Executions.Events do
  @moduledoc """
  Canonical execution lifecycle event contract and broadcaster.

  All runtime and execution lifecycle events should be emitted through this module.
  """

  require Logger

  alias Fizz.Executions.PubSub
  alias Fizz.Serializer

  @execution_lifecycle_events [
    :execution_started,
    :execution_updated,
    :execution_completed,
    :execution_cancelled,
    :execution_failed
  ]
  @step_lifecycle_events [
    :step_started,
    :step_completed,
    :step_failed,
    :step_skipped,
    :step_cancelled
  ]

  @type event_name ::
          :execution_started
          | :execution_updated
          | :execution_completed
          | :execution_cancelled
          | :execution_failed
          | :step_started
          | :step_completed
          | :step_failed
          | :step_skipped
          | :step_cancelled

  @type event :: %{
          event_name: event_name(),
          execution_id: String.t(),
          workflow_id: String.t() | nil,
          occurred_at: DateTime.t(),
          payload: map(),
          meta: %{
            schema_version: pos_integer(),
            source: atom()
          }
        }

  @doc """
  Emits a canonical execution lifecycle event.

  ## Options

  - `:workflow_id` - workflow id for workflow-level broadcasts
  - `:source` - event producer identifier
  """
  @spec emit(event_name(), String.t(), map(), keyword()) :: :ok
  def emit(event_name, execution_id, payload \\ %{}, opts \\ [])
      when is_binary(execution_id) and is_map(payload) and is_list(opts) do
    event = build_event(event_name, execution_id, payload, opts)

    log_event(event)
    broadcast_event(event)
    emit_telemetry(event)

    :ok
  end

  @spec execution_lifecycle_event?(term()) :: boolean()
  def execution_lifecycle_event?(event_name), do: event_name in @execution_lifecycle_events

  @spec step_lifecycle_event?(term()) :: boolean()
  def step_lifecycle_event?(event_name), do: event_name in @step_lifecycle_events

  defp build_event(event_name, execution_id, payload, opts) do
    %{
      event_name: event_name,
      execution_id: execution_id,
      workflow_id: workflow_id(opts, payload),
      occurred_at: DateTime.utc_now(),
      payload: sanitize_payload(payload),
      meta: %{
        schema_version: 1,
        source: event_source(opts)
      }
    }
  end

  defp event_source(opts) do
    case Keyword.get(opts, :source, :runtime) do
      source when is_atom(source) -> source
      _ -> :runtime
    end
  end

  defp workflow_id(opts, payload) do
    case Keyword.get(opts, :workflow_id) do
      workflow_id when is_binary(workflow_id) and byte_size(workflow_id) > 0 ->
        workflow_id

      _ ->
        fetch_payload_value(payload, :workflow_id)
    end
  end

  defp broadcast_event(event) do
    message = {:execution_event, event}
    broadcast(PubSub.execution_topic(event.execution_id), message)

    if is_binary(event.workflow_id) do
      broadcast(PubSub.workflow_executions_topic(event.workflow_id), message)
    end
  rescue
    e ->
      Logger.warning("Failed to broadcast execution event",
        event_name: event.event_name,
        execution_id: event.execution_id,
        reason: inspect(e)
      )
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(Fizz.PubSub, topic, message)
  end

  defp sanitize_payload(payload) when is_map(payload) do
    Serializer.sanitize(payload)
  rescue
    _ -> %{error: "Failed to sanitize payload"}
  end

  defp log_event(%{event_name: event_name} = event) do
    if event_log_level(event_name) == :error do
      Logger.error(event_message(event_name),
        event_name: event_name,
        execution_id: event.execution_id,
        workflow_id: event.workflow_id,
        payload: event.payload
      )
    end
  end

  defp emit_telemetry(event) do
    :telemetry.execute(
      [:fizz, :execution, :event],
      %{system_time: System.system_time()},
      %{
        event_name: event.event_name,
        execution_id: event.execution_id,
        workflow_id: event.workflow_id,
        payload: event.payload,
        meta: event.meta
      }
    )
  end

  defp event_log_level(:execution_failed), do: :error
  defp event_log_level(:step_failed), do: :error
  defp event_log_level(_event_name), do: :info

  defp event_message(:execution_started), do: "Execution started"
  defp event_message(:execution_updated), do: "Execution updated"
  defp event_message(:execution_completed), do: "Execution completed"
  defp event_message(:execution_cancelled), do: "Execution cancelled"
  defp event_message(:execution_failed), do: "Execution failed"
  defp event_message(:step_started), do: "Step started"
  defp event_message(:step_completed), do: "Step completed"
  defp event_message(:step_failed), do: "Step failed"
  defp event_message(:step_skipped), do: "Step skipped"
  defp event_message(:step_cancelled), do: "Step cancelled"
  defp event_message(event_name), do: "Execution event: #{inspect(event_name)}"

  defp fetch_payload_value(payload, key) when is_map(payload) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(payload, key) -> Map.get(payload, key)
      Map.has_key?(payload, string_key) -> Map.get(payload, string_key)
      true -> nil
    end
  end
end
