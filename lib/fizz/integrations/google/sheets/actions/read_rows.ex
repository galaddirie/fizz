defmodule Fizz.Integrations.Google.Sheets.Actions.ReadRows do
  @moduledoc """
  Reads rows from a Google Sheet range.
  """

  @behaviour Fizz.Integrations.Operation

  alias Fizz.Integrations.Google.Sheets.Client
  alias Fizz.Integrations.Google.Sheets.Rows

  @impl true
  def id, do: "google_sheets.read_rows"

  @impl true
  def schema, do: %{"type" => "object"}

  @impl true
  def execute(config, _input, context) do
    range = Map.get(config, "range", "#{Map.get(config, "sheet_name", "Sheet1")}!A:ZZZ")

    with {:ok, values} <- Client.get_values(config, context, range) do
      rows =
        values
        |> Rows.snapshots(config, DateTime.utc_now(), %{})
        |> Enum.map(&Map.take(&1, [:row_number, :values, :raw_values]))

      {:ok, %{"rows" => rows, "total_rows" => length(rows)}}
    end
  end
end
