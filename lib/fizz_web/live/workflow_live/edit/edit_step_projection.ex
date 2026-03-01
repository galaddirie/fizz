defmodule FizzWeb.WorkflowLive.Edit.EditStepProjection do
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
        started_at:
          payload
          |> fetch_payload_value(:started_at)
          |> normalize_timestamp(),
        completed_at:
          payload
          |> fetch_payload_value(:completed_at)
          |> normalize_timestamp(),
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

  defp normalize_timestamp(nil), do: nil
  defp normalize_timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_timestamp(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_timestamp(value) when is_binary(value), do: value
  defp normalize_timestamp(value) when is_map(value), do: normalize_sanitized_datetime(value)
  defp normalize_timestamp(_value), do: nil

  defp normalize_sanitized_datetime(value) when is_map(value) do
    with {:ok, year} <- fetch_integer(value, :year),
         {:ok, month} <- fetch_integer(value, :month),
         {:ok, day} <- fetch_integer(value, :day),
         {:ok, hour} <- fetch_integer(value, :hour),
         {:ok, minute} <- fetch_integer(value, :minute),
         {:ok, second} <- fetch_integer(value, :second),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second, normalize_microsecond(value)),
         {:ok, naive_datetime} <- NaiveDateTime.new(date, time),
         {:ok, datetime} <- DateTime.from_naive(naive_datetime, "Etc/UTC") do
      value
      |> total_offset_seconds()
      |> then(&DateTime.add(datetime, -&1, :second))
      |> DateTime.to_iso8601()
    else
      _ -> nil
    end
  end

  defp fetch_integer(map, key) when is_map(map) do
    case fetch_payload_value(map, key) do
      value when is_integer(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp normalize_microsecond(map) when is_map(map) do
    case fetch_payload_value(map, :microsecond) do
      [value, precision] when is_integer(value) and is_integer(precision) -> {value, precision}
      {value, precision} when is_integer(value) and is_integer(precision) -> {value, precision}
      value when is_integer(value) -> {value, 6}
      _ -> {0, 0}
    end
  end

  defp total_offset_seconds(map) when is_map(map) do
    map
    |> fetch_payload_value(:utc_offset)
    |> normalize_offset_seconds()
    |> Kernel.+(
      map
      |> fetch_payload_value(:std_offset)
      |> normalize_offset_seconds()
    )
  end

  defp normalize_offset_seconds(value) when is_integer(value), do: value
  defp normalize_offset_seconds(_value), do: 0

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
          Map.get(existing, :step_id) == step_id and
            is_nil(Map.get(existing, :item_index)) and
            replaceable_summary_step_execution?(existing)
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

  defp replaceable_summary_step_execution?(step_execution) do
    case Map.get(step_execution, :status) do
      nil -> true
      :pending -> true
      "pending" -> true
      :queued -> true
      "queued" -> true
      :running -> true
      "running" -> true
      _ -> false
    end
  end

  defp step_status_rank(status) do
    case status do
      :pending -> 0
      "pending" -> 0
      :queued -> 1
      "queued" -> 1
      :running -> 2
      "running" -> 2
      :completed -> 3
      "completed" -> 3
      :skipped -> 3
      "skipped" -> 3
      :cancelled -> 4
      "cancelled" -> 4
      :failed -> 5
      "failed" -> 5
      _ -> -1
    end
  end
end
