defmodule Fizz.Integrations.Google.Sheets.Actions.AppendRow do
  @moduledoc """
  Appends a single row to a Google Sheet.
  """

  @behaviour Fizz.Integrations.Operation

  alias Fizz.Integrations.Google.Sheets.Client

  @impl true
  def id, do: "google_sheets.append_row"

  @impl true
  def schema, do: %{"type" => "object"}

  @impl true
  def execute(config, input, context) do
    values = Map.get(config, "values", input)
    sheet_name = Map.get(config, "sheet_name", "Sheet1")
    range = Map.get(config, "range", "#{sheet_name}!A:ZZZ")

    with {:ok, row} <- normalize_row(values),
         {:ok, result} <- Client.append_values(config, context, range, [row]) do
      {:ok,
       %{
         "updated_range" => get_in(result, ["updates", "updatedRange"]),
         "updated_rows" => get_in(result, ["updates", "updatedRows"])
       }}
    end
  end

  defp normalize_row(values) when is_list(values), do: {:ok, values}

  defp normalize_row(values) when is_map(values) do
    values
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {_key, value} -> value end)
    |> then(&{:ok, &1})
  end

  defp normalize_row(_values), do: {:error, :invalid_row_values}
end
