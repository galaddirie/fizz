defmodule Fizz.Integrations.Google.Sheets.Rows do
  @moduledoc """
  Row normalization and hashing helpers for Google Sheets polling.
  """

  @spec snapshots([list()], map(), DateTime.t(), map()) :: [map()]
  def snapshots(values, params, now, existing_by_key \\ %{}) when is_list(values) do
    header_row = positive_integer(params["header_row"], 1)
    first_data_row = positive_integer(params["first_data_row"], header_row + 1)
    headers = values |> Enum.at(header_row - 1, []) |> normalize_raw_values()

    values
    |> Enum.with_index(1)
    |> Enum.filter(fn {_row, row_number} -> row_number >= first_data_row end)
    |> Enum.reject(fn {row, _row_number} -> empty_row?(row) end)
    |> Enum.map(fn {row, row_number} ->
      raw_values = normalize_raw_values(row)
      values_map = values_map(headers, raw_values)
      row_key = row_key(params, headers, raw_values, row_number)
      row_hash = row_hash(raw_values)
      existing = Map.get(existing_by_key, row_key)
      changed_at = changed_at(existing, row_hash, now)

      %{
        row_key: row_key,
        row_number: row_number,
        row_hash: row_hash,
        values: values_map,
        raw_values: raw_values,
        last_seen_at: now,
        last_changed_at: changed_at
      }
    end)
  end

  @spec change_events([map()], map(), String.t(), map()) :: [map()]
  def change_events(snapshots, existing_by_key, event_mode, params) do
    for snapshot <- snapshots,
        event = change_event(snapshot, existing_by_key, event_mode, params),
        not is_nil(event) do
      event
    end
  end

  defp change_event(snapshot, existing_by_key, event_mode, params) do
    case Map.get(existing_by_key, snapshot.row_key) do
      nil ->
        if event_mode in ["row_added", "row_added_or_updated"] do
          event(snapshot, nil, "added", params)
        end

      existing ->
        if existing.row_hash != snapshot.row_hash and
             event_mode in ["row_updated", "row_added_or_updated"] do
          event(snapshot, existing, "updated", params)
        end
    end
  end

  defp event(snapshot, existing, change_type, params) do
    %{
      "spreadsheet_id" => params["spreadsheet_id"],
      "sheet_name" => params["sheet_name"],
      "range" => params["range"],
      "change_type" => change_type,
      "row_key" => snapshot.row_key,
      "row_number" => snapshot.row_number,
      "row_hash" => snapshot.row_hash,
      "values" => snapshot.values,
      "raw_values" => snapshot.raw_values,
      "previous_values" => previous_values(existing),
      "detected_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp previous_values(nil), do: nil
  defp previous_values(existing), do: existing.values

  defp values_map(headers, raw_values) do
    raw_values
    |> Enum.with_index()
    |> Map.new(fn {value, index} ->
      header = Enum.at(headers, index) || "col_#{index + 1}"
      {normalize_header(header, index), value}
    end)
  end

  defp row_key(%{"primary_key_column" => column}, headers, raw_values, row_number)
       when is_binary(column) and column != "" do
    case Enum.find_index(headers, &(&1 == column)) do
      nil ->
        "row:#{row_number}"

      index ->
        case Enum.at(raw_values, index, "") do
          "" -> "row:#{row_number}"
          value -> "pk:#{value}"
        end
    end
  end

  defp row_key(_params, _headers, _raw_values, row_number), do: "row:#{row_number}"

  defp row_hash(raw_values) do
    raw_values
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp changed_at(nil, _row_hash, now), do: now

  defp changed_at(existing, row_hash, now) do
    case existing.row_hash == row_hash do
      true -> existing.last_changed_at || now
      false -> now
    end
  end

  defp normalize_raw_values(values) when is_list(values), do: Enum.map(values, &cell_to_string/1)
  defp normalize_raw_values(_values), do: []

  defp empty_row?(values) when is_list(values) do
    values
    |> normalize_raw_values()
    |> Enum.all?(&(&1 == ""))
  end

  defp empty_row?(_values), do: true

  defp cell_to_string(nil), do: ""
  defp cell_to_string(value) when is_binary(value), do: value
  defp cell_to_string(value) when is_integer(value), do: Integer.to_string(value)

  defp cell_to_string(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 10)

  defp cell_to_string(value) when is_boolean(value), do: to_string(value)
  defp cell_to_string(value), do: Jason.encode!(value)

  defp normalize_header("", index), do: "col_#{index + 1}"
  defp normalize_header(header, _index), do: header

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default
end
