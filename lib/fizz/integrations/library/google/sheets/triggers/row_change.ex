defmodule Fizz.Integrations.Library.Google.Sheets.Triggers.RowChange do
  @moduledoc """
  Polling source for Google Sheets row additions and updates.
  """

  @behaviour Fizz.Triggers.Source

  alias Fizz.Integrations.Library.Google.Sheets.Client
  alias Fizz.Integrations.Library.Google.Sheets.Rows
  alias Fizz.Triggers

  @default_range "A:ZZZ"

  @impl true
  def source_key(params, context) do
    %{
      "source" => "google_sheets_row_change",
      "user_id" => context.user_id,
      "credential_ref" => credential_ref_id(params["credential_ref"]),
      "spreadsheet_id" => params["spreadsheet_id"],
      "sheet_name" => params["sheet_name"],
      "range" => params["range"],
      "event_mode" => params["event_mode"],
      "primary_key_column" => params["primary_key_column"]
    }
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @impl true
  def init_cursor(_params, _context), do: {:ok, %{"initialized" => false}}

  @impl true
  def poll(params, cursor, context) do
    with {:ok, range} <- range(params),
         {:ok, values} <- Client.get_values(params, context, range) do
      existing_rows = Triggers.list_source_rows(context.source_id)
      existing_by_key = Map.new(existing_rows, &{&1.row_key, &1})
      now = DateTime.utc_now()
      snapshots = Rows.snapshots(values, params, now, existing_by_key)

      events =
        case initialized?(cursor, existing_rows) do
          true -> Rows.change_events(snapshots, existing_by_key, event_mode(params), params)
          false -> []
        end

      {:ok,
       %{
         events: events,
         cursor: %{
           "initialized" => true,
           "last_row_count" => length(snapshots),
           "last_polled_at" => DateTime.to_iso8601(now)
         },
         checkpoint: %{rows: snapshots}
       }}
    end
  end

  @impl true
  def commit(_params, %{rows: rows}, context) when is_list(rows) do
    Triggers.replace_source_rows(context.source_id, rows)
  end

  def commit(_params, _checkpoint, _context), do: :ok

  @impl true
  def event_id(event) when is_map(event) do
    [
      "google_sheets",
      event["spreadsheet_id"],
      event["sheet_name"],
      event["change_type"],
      event["row_key"],
      event["row_hash"]
    ]
    |> Enum.join(":")
  end

  defp range(params) do
    with {:ok, sheet_name} <- fetch_string(params, "sheet_name") do
      range = Map.get(params, "range", @default_range)

      if String.contains?(range, "!") do
        {:ok, range}
      else
        {:ok, "#{sheet_name}!#{range}"}
      end
    end
  end

  defp initialized?(%{"initialized" => true}, _existing_rows), do: true
  defp initialized?(_cursor, [_row | _rows]), do: true
  defp initialized?(_cursor, []), do: false

  defp event_mode(%{"event_mode" => event_mode})
       when event_mode in [
              "row_added",
              "row_updated",
              "row_added_or_updated"
            ],
       do: event_mode

  defp event_mode(_params), do: "row_added_or_updated"

  defp credential_ref_id(%{"id" => id}) when is_binary(id), do: id
  defp credential_ref_id(_credential_ref), do: nil

  defp fetch_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_param, key}}
    end
  end
end
