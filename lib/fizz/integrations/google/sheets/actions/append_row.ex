defmodule Fizz.Integrations.Google.Sheets.Actions.AppendRow do
  @moduledoc """
  Appends one or more rows to a Google Sheet.

  When `values` is a map, the row is built in the order of either the selected
  native table's columns or the sheet's actual header row (fetched at execution
  time), so authors can reference columns by name without worrying about column
  position. When `values` is a list of maps, each map is projected the same way.
  Positional list rows pass through without requiring headers.
  """

  use Fizz.Steps.Definition,
    id: "google_sheets_append_row",
    version: 1,
    name: "Google Sheets — Append Row",
    category: "Documents",
    description: "Append a new row of data to a Google Sheet",
    icon: "/images/google_sheets.svg",
    kind: :action,
    provider: Fizz.Integrations.Providers.GoogleOAuth.provider_id(),
    integration: "google_sheets"

  alias Fizz.Fields

  alias Fizz.Integrations.{Google.Sheets.Client, Providers.GoogleOAuth}
  alias Fizz.Workflows.RetryPolicy

  @behaviour Fizz.Steps.Executor

  @spreadsheet_locator %{
    "kind" => "google_sheets.spreadsheet",
    "value_key" => "spreadsheet_id"
  }
  @values_depends_on ["credential_ref", "spreadsheet_id", "sheet_name", "table_id"]
  @row_values_mapper %{
    "kind" => "google_sheets.row_values",
    "fields" => %{
      "primary_resource" => "sheet_name",
      "schema_resource" => "table_id"
    },
    "labels" => %{
      "primary_resource" => "Sheet",
      "schema_resource" => "Table",
      "no_primary_resource" => "No sheet",
      "no_schema_resource" => "No table",
      "selected_schema_fallback" => "No table selected",
      "schema_locked" => "Schema locked",
      "freeform" => "Freeform",
      "empty_state" => "Flexible columns",
      "lookup_loading" => "Loading table schema; editing stays available",
      "lookup_failed" => "Table lookup failed; editing stays available",
      "schema_unavailable" => "Table schema unavailable; editing stays available",
      "refresh_idle" => "Refresh sheets and tables",
      "refresh_loading" => "Refreshing resource metadata"
    },
    "lookups" => %{
      "primary_resource" => %{
        "mode" => "sheets",
        "params" => %{
          "credential_ref" => "credential_ref",
          "spreadsheet_id" => "spreadsheet_id"
        }
      },
      "schema_resource" => %{
        "mode" => "tables",
        "params" => %{
          "credential_ref" => "credential_ref",
          "spreadsheet_id" => "spreadsheet_id"
        },
        "parent_option_field" => "sheet_name"
      }
    },
    "errors" => %{
      "primary_resource" => %{
        "no_google_credential" => "Connect a Google account to load this spreadsheet's sheets.",
        "unauthorized" => "Your Google account does not have access to this spreadsheet.",
        "forbidden" => "Your Google account does not have access to this spreadsheet.",
        "spreadsheet_not_found" =>
          "Couldn't find that spreadsheet. Double-check the Spreadsheet ID.",
        "invalid_range_or_sheet" =>
          "Couldn't read that sheet. Make sure the Sheet Name matches the tab in Google Sheets exactly.",
        "rate_limited" => "Google rate-limited the lookup. Try again in a moment.",
        "fetch_failed" => "Could not load sheets from this spreadsheet."
      },
      "schema_resource" => %{
        "no_google_credential" => "Connect a Google account to load this spreadsheet's tables.",
        "unauthorized" => "Your Google account does not have access to this spreadsheet.",
        "forbidden" => "Your Google account does not have access to this spreadsheet.",
        "spreadsheet_not_found" =>
          "Couldn't find that spreadsheet. Double-check the Spreadsheet ID.",
        "rate_limited" => "Google rate-limited the lookup. Try again in a moment.",
        "fetch_failed" => "Could not load tables from this spreadsheet."
      }
    }
  }

  @field_display %{
    "values" => %{
      "empty_state" => "Flexible columns",
      "schema_state" => "Schema locked"
    }
  }
  @fields [
    Fields.credential(GoogleOAuth.provider_id(), :oauth,
      key: "credential_ref",
      label: "Google Account",
      requirement_key: "auth",
      required?: true,
      order: 10
    ),
    Fields.resource_locator("spreadsheet_id", @spreadsheet_locator,
      label: "Spreadsheet ID",
      required?: true,
      order: 20
    ),
    Fields.hidden("sheet_name",
      label: "Sheet Name",
      default: "",
      order: 30
    ),
    Fields.hidden("table_id",
      label: "Table ID",
      default: "",
      order: 40
    ),
    Fields.resource_mapper("values", @row_values_mapper,
      label: "Row Values",
      description: "Map a value to each column in your sheet.",
      required?: true,
      resolver: Fizz.Integrations.Google.Sheets.ColumnsResolver,
      depends_on: @values_depends_on,
      display: @field_display["values"],
      order: 50
    )
  ]
  @retry_policy %RetryPolicy{
    max_attempts: 3,
    backoff: :exponential,
    initial_delay_ms: 1_000,
    max_delay_ms: 60_000,
    retry_on: [:rate_limit, :network, :transient]
  }

  @retry @retry_policy

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "updated_range" => %{"type" => "string"},
      "updated_rows" => %{"type" => "integer"}
    }
  }

  @doc false
  def fields, do: @fields

  @doc false
  def output_schema, do: @output_schema

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
