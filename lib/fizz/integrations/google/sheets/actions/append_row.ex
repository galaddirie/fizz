defmodule Fizz.Integrations.Google.Sheets.Actions.AppendRow do
  @moduledoc """
  Appends one or more rows to a Google Sheet.

  When `values` is a map, the row is built in the order of either the selected
  native table's columns or the sheet's actual header row (fetched at execution
  time), so authors can reference columns by name without worrying about column
  position. When `values` is a list of maps, each map is projected the same way.
  Positional list rows pass through without requiring headers.
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
    sheet_name = config_string(config, "sheet_name", "Sheet1")
    table_id = config_string(config, "table_id", "")
    range = config_string(config, "range", "#{sheet_name}!A:ZZZ")
    header_row = Map.get(config, "header_row", 1)

    with {:ok, rows} <- prepare_rows(values, config, context, table_id, sheet_name, header_row),
         {:ok, result} <- append_rows(config, context, table_id, range, rows) do
      {:ok,
       %{
         "updated_range" => updated_range(result),
         "updated_rows" => updated_rows(result, rows)
       }}
    end
  end

  @doc """
  Builds the ordered row list to append given the author-supplied `values`
  and the actual header row from the target sheet.

  - List values pass through unchanged.
  - Map values are projected onto `headers` in order; missing keys become `""`.
  """
  @spec build_row(list() | map(), [String.t()]) :: {:ok, [term()]} | {:error, term()}
  def build_row(values, _headers) when is_list(values), do: {:ok, values}

  def build_row(values, headers) when is_map(values) and is_list(headers) do
    {:ok, Enum.map(headers, &Map.get(values, &1, ""))}
  end

  def build_row(_values, _headers), do: {:error, :invalid_row_values}

  @doc """
  Builds one or more ordered rows to append.

  - A list of scalar values is treated as one positional row.
  - A list of lists is treated as multiple positional rows.
  - A map is treated as one named row.
  - A list of maps is treated as multiple named rows.
  """
  @spec build_rows(list() | map(), [String.t()]) :: {:ok, [list()]} | {:error, term()}
  def build_rows([], _headers), do: {:ok, [[]]}

  def build_rows([first | _] = values, headers) when is_map(first) do
    case Enum.all?(values, &is_map/1) do
      true -> build_mapped_rows(values, headers)
      false -> {:error, :invalid_row_values}
    end
  end

  def build_rows([first | _] = values, _headers) when is_list(first) do
    case Enum.all?(values, &is_list/1) do
      true -> {:ok, values}
      false -> {:error, :invalid_row_values}
    end
  end

  def build_rows(values, _headers) when is_list(values), do: {:ok, [values]}

  def build_rows(values, headers) when is_map(values) do
    with {:ok, row} <- build_row(values, headers) do
      {:ok, [row]}
    end
  end

  def build_rows(_values, _headers), do: {:error, :invalid_row_values}

  defp prepare_rows([first | _] = values, config, context, table_id, sheet_name, header_row)
       when is_map(first) do
    with {:ok, headers} <- fetch_headers(config, context, table_id, sheet_name, header_row) do
      build_rows(values, headers)
    end
  end

  defp prepare_rows(values, _config, _context, _table_id, _sheet_name, _header_row)
       when is_list(values),
       do: build_rows(values, [])

  defp prepare_rows(values, config, context, table_id, sheet_name, header_row)
       when is_map(values) do
    with {:ok, headers} <- fetch_headers(config, context, table_id, sheet_name, header_row) do
      build_rows(values, headers)
    end
  end

  defp prepare_rows(_values, _config, _context, _table_id, _sheet_name, _header_row),
    do: {:error, :invalid_row_values}

  defp fetch_headers(config, context, "", sheet_name, header_row) do
    case Client.get_headers(config, context, sheet_name: sheet_name, header_row: header_row) do
      {:ok, []} -> {:error, :no_header_row}
      {:ok, headers} -> {:ok, headers}
      other -> other
    end
  end

  defp fetch_headers(config, context, table_id, _sheet_name, _header_row) do
    case Client.get_table_headers(config, context, table_id) do
      {:ok, []} -> {:error, :no_header_row}
      {:ok, headers} -> {:ok, headers}
      other -> other
    end
  end

  defp append_rows(config, context, "", range, rows),
    do: Client.append_values(config, context, range, rows)

  defp append_rows(config, context, table_id, _range, rows),
    do: Client.append_table_values(config, context, table_id, rows)

  defp updated_range(result), do: get_in(result, ["updates", "updatedRange"])

  defp updated_rows(%{"appendedRows" => count}, _rows), do: count

  defp updated_rows(result, _rows) do
    get_in(result, ["updates", "updatedRows"])
  end

  defp config_string(config, key, default) do
    case Map.get(config, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      _ ->
        default
    end
  end

  defp build_mapped_rows(values, headers) do
    result =
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, rows} ->
        case build_row(value, headers) do
          {:ok, row} -> {:cont, {:ok, [row | rows]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, reason} -> {:error, reason}
    end
  end
end
