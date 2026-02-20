defmodule FizzWeb.WorkflowLive.EditStepProjection do
  @moduledoc false

  @step_lifecycle_events [
    :step_started,
    :step_completed,
    :step_failed,
    :step_skipped,
    :step_cancelled
  ]

  @spec apply_event([map()], String.t() | nil, atom(), map()) :: [map()]
  def apply_event(step_executions, execution_id, event_name, payload)
      when is_list(step_executions) and event_name in @step_lifecycle_events and is_map(payload) do
    case normalize_step_payload(payload, execution_id, event_name) do
      nil -> step_executions
      step_execution -> upsert_step_execution(step_executions, step_execution)
    end
  end

  def apply_event(step_executions, _execution_id, _event_name, _payload), do: step_executions

  defp normalize_step_payload(payload, execution_id, event_name) do
    step_id = fetch_payload_value(payload, :step_id)
    payload_execution_id = fetch_payload_value(payload, :execution_id) || execution_id
    item_index = fetch_payload_value(payload, :item_index)
    attempt = parse_attempt(fetch_payload_value(payload, :attempt))

    if step_id && payload_execution_id && payload_execution_id == execution_id do
      %{
        id:
          fetch_payload_value(payload, :id) ||
            step_execution_id(payload_execution_id, step_id, item_index, attempt),
        execution_id: payload_execution_id,
        step_id: step_id,
        step_type_id: fetch_payload_value(payload, :step_type_id),
        status: fetch_payload_value(payload, :status) || default_step_status(event_name),
        input_data: fetch_payload_value(payload, :input_data),
        output_data: fetch_payload_value(payload, :output_data),
        output_item_count: fetch_payload_value(payload, :output_item_count),
        item_index: item_index,
        items_total: fetch_payload_value(payload, :items_total),
        error: fetch_payload_value(payload, :error),
        attempt: attempt,
        retry_of_id: fetch_payload_value(payload, :retry_of_id),
        queued_at: fetch_payload_value(payload, :queued_at),
        started_at: fetch_payload_value(payload, :started_at),
        completed_at: fetch_payload_value(payload, :completed_at),
        duration_us: fetch_payload_value(payload, :duration_us),
        metadata: fetch_payload_value(payload, :metadata)
      }
    end
  end

  defp parse_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt

  defp parse_attempt(attempt) when is_binary(attempt) do
    case Integer.parse(attempt) do
      {parsed, _rest} when parsed > 0 -> parsed
      _ -> 1
    end
  end

  defp parse_attempt(_attempt), do: 1

  defp fetch_payload_value(payload, key) when is_map(payload) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(payload, key) -> Map.get(payload, key)
      Map.has_key?(payload, string_key) -> Map.get(payload, string_key)
      true -> nil
    end
  end

  defp default_step_status(:step_started), do: :running
  defp default_step_status(:step_failed), do: :failed
  defp default_step_status(:step_completed), do: :completed
  defp default_step_status(:step_skipped), do: :skipped
  defp default_step_status(:step_cancelled), do: :cancelled
  defp default_step_status(_event_name), do: :pending

  defp step_execution_id(execution_id, step_id, nil, attempt) do
    "#{execution_id}:#{step_id}:#{attempt}"
  end

  defp step_execution_id(execution_id, step_id, item_index, attempt) do
    "#{execution_id}:#{step_id}:#{item_index}:#{attempt}"
  end

  defp upsert_step_execution(step_executions, step_execution) do
    step_id = Map.get(step_execution, :step_id)
    item_index = Map.get(step_execution, :item_index)
    attempt = Map.get(step_execution, :attempt) || 1

    step_executions =
      if is_nil(item_index) do
        step_executions
      else
        Enum.reject(step_executions, fn existing ->
          Map.get(existing, :step_id) == step_id and is_nil(Map.get(existing, :item_index))
        end)
      end

    case Enum.find_index(step_executions, fn existing ->
           Map.get(existing, :step_id) == step_id and
             Map.get(existing, :item_index) == item_index and
             (Map.get(existing, :attempt) || 1) == attempt
         end) do
      nil ->
        step_executions ++ [step_execution]

      index ->
        existing = Enum.at(step_executions, index)
        resolved_status = resolve_step_status(existing, step_execution)

        updated =
          Enum.reduce(step_execution, existing, fn {key, value}, acc ->
            if key == :status or is_nil(value) do
              acc
            else
              Map.put(acc, key, value)
            end
          end)
          |> Map.put(:status, resolved_status)

        List.replace_at(step_executions, index, updated)
    end
  end

  defp resolve_step_status(existing, incoming) do
    existing_status = Map.get(existing, :status)
    incoming_status = Map.get(incoming, :status)
    existing_rank = step_status_rank(existing_status)
    incoming_rank = step_status_rank(incoming_status)

    cond do
      is_nil(existing_status) -> incoming_status
      is_nil(incoming_status) -> existing_status
      incoming_rank < existing_rank -> existing_status
      true -> incoming_status
    end
  end

  defp step_status_rank(status) do
    case status do
      :pending -> 0
      "pending" -> 0
      :running -> 1
      "running" -> 1
      :completed -> 2
      "completed" -> 2
      :skipped -> 2
      "skipped" -> 2
      :failed -> 3
      "failed" -> 3
      :cancelled -> 3
      "cancelled" -> 3
      _ -> -1
    end
  end
end
