defmodule Fizz.Integrations.Google.Sheets.Client do
  @moduledoc """
  Minimal Google Sheets API client backed by Req.
  """

  alias Fizz.Accounts.Scope
  alias Fizz.Accounts.User
  alias Fizz.Integrations
  alias Fizz.Integrations.Providers.GoogleOAuth
  alias Fizz.Repo

  @sheets_base_url "https://sheets.googleapis.com/v4"

  @spec get_values(map(), map(), String.t(), keyword()) ::
          {:ok, [list()]} | {:backoff, term()} | {:error, term()}
  def get_values(params, context, range, opts \\ []) do
    query =
      %{
        valueRenderOption: Keyword.get(opts, :value_render_option, "UNFORMATTED_VALUE"),
        dateTimeRenderOption: Keyword.get(opts, :date_time_render_option, "SERIAL_NUMBER")
      }

    with {:ok, spreadsheet_id} <- fetch_string(params, "spreadsheet_id"),
         {:ok, token} <- access_token(params, context),
         {:ok, body} <-
           request(
             :get,
             "#{@sheets_base_url}/spreadsheets/#{spreadsheet_id}/values/#{encode_range(range)}",
             token: token,
             params: query
           ) do
      {:ok, Map.get(body, "values", [])}
    end
  end

  @spec get_headers(map(), map(), keyword()) ::
          {:ok, [String.t()]} | {:backoff, term()} | {:error, term()}
  def get_headers(params, context, opts \\ []) do
    sheet_name = Keyword.get(opts, :sheet_name, "Sheet1")
    header_row = Keyword.get(opts, :header_row, 1)
    range = "#{quote_sheet_name(sheet_name)}!#{header_row}:#{header_row}"

    case get_values(params, context, range, opts) do
      {:ok, [row | _]} when is_list(row) -> {:ok, normalize_headers(row)}
      {:ok, _} -> {:ok, []}
      other -> other
    end
  end

  @spec get_sheet_names(map(), map(), keyword()) ::
          {:ok, [String.t()]} | {:backoff, term()} | {:error, term()}
  def get_sheet_names(params, context, opts \\ []) do
    query = %{fields: Keyword.get(opts, :fields, "sheets.properties.title")}

    with {:ok, spreadsheet_id} <- fetch_string(params, "spreadsheet_id"),
         {:ok, token} <- access_token(params, context),
         {:ok, body} <-
           request(
             :get,
             "#{@sheets_base_url}/spreadsheets/#{spreadsheet_id}",
             token: token,
             params: query
           ) do
      {:ok, sheet_names(body)}
    end
  end

  @spec get_tables(map(), map(), keyword()) ::
          {:ok, [map()]} | {:backoff, term()} | {:error, term()}
  def get_tables(params, context, opts \\ []) do
    query = %{
      fields:
        Keyword.get(
          opts,
          :fields,
          "sheets.properties(sheetId,title),sheets.tables(tableId,name,range,columnProperties(columnIndex,columnName,columnType))"
        )
    }

    with {:ok, spreadsheet_id} <- fetch_string(params, "spreadsheet_id"),
         {:ok, token} <- access_token(params, context),
         {:ok, body} <-
           request(
             :get,
             "#{@sheets_base_url}/spreadsheets/#{spreadsheet_id}",
             token: token,
             params: query
           ) do
      tables =
        body
        |> tables()
        |> enrich_table_header_rows(spreadsheet_id, token)

      {:ok, tables}
    end
  end

  @spec get_table_headers(map(), map(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:backoff, term()} | {:error, term()}
  def get_table_headers(params, context, table_id, opts \\ []) when is_binary(table_id) do
    with {:ok, tables} <- get_tables(params, context, opts) do
      case Enum.find(tables, &(Map.get(&1, "id") == table_id)) do
        nil ->
          {:error, :table_not_found}

        table ->
          {:ok, Enum.map(Map.get(table, "columns", []), &Map.get(&1, "label"))}
      end
    end
  end

  defp quote_sheet_name(sheet_name) when is_binary(sheet_name) do
    if Regex.match?(~r/^[A-Za-z0-9_]+$/, sheet_name) do
      sheet_name
    else
      "'" <> String.replace(sheet_name, "'", "''") <> "'"
    end
  end

  @spec append_values(map(), map(), String.t(), [list()], keyword()) ::
          {:ok, map()} | {:backoff, term()} | {:error, term()}
  def append_values(params, context, range, rows, opts \\ [])
      when is_list(rows) do
    query =
      %{
        valueInputOption: Keyword.get(opts, :value_input_option, "USER_ENTERED"),
        insertDataOption: Keyword.get(opts, :insert_data_option, "INSERT_ROWS")
      }

    with {:ok, spreadsheet_id} <- fetch_string(params, "spreadsheet_id"),
         {:ok, token} <- access_token(params, context),
         {:ok, body} <-
           request(
             :post,
             "#{@sheets_base_url}/spreadsheets/#{spreadsheet_id}/values/#{encode_range(range)}:append",
             token: token,
             params: query,
             json: %{values: rows}
           ) do
      {:ok, body}
    end
  end

  @spec append_table_values(map(), map(), String.t(), [list()], keyword()) ::
          {:ok, map()} | {:backoff, term()} | {:error, term()}
  def append_table_values(params, context, table_id, rows, _opts \\ [])
      when is_binary(table_id) and is_list(rows) do
    body = %{
      requests: [
        %{
          appendCells: %{
            tableId: table_id,
            rows: row_data(rows),
            fields: "userEnteredValue"
          }
        }
      ]
    }

    with {:ok, spreadsheet_id} <- fetch_string(params, "spreadsheet_id"),
         {:ok, token} <- access_token(params, context),
         {:ok, response} <-
           request(
             :post,
             "#{@sheets_base_url}/spreadsheets/#{spreadsheet_id}:batchUpdate",
             token: token,
             json: body
           ) do
      {:ok, Map.put(response, "appendedRows", length(rows))}
    end
  end

  defp request(method, url, opts) do
    req_opts =
      [
        method: method,
        url: url,
        headers: [{"authorization", "Bearer #{Keyword.fetch!(opts, :token)}"}],
        params: Keyword.get(opts, :params, %{})
      ]
      |> maybe_put_json(Keyword.get(opts, :json))
      |> Keyword.merge(Application.get_env(:fizz, :google_sheets_req_options, []))

    case Req.request(req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 429, headers: headers, body: body}} ->
        {:backoff, %{status: 429, retry_after_ms: retry_after_ms(headers), body: body}}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp access_token(params, context) do
    with {:ok, credential_ref} <- credential_ref(params),
         {:ok, scope} <- scope_from_context(context),
         {:ok, project_id} <- context_string(context, :project_id) do
      with {:ok, auth} <-
             Integrations.resolve_auth_for_execution(
               scope,
               project_id,
               GoogleOAuth.provider_id(),
               credential_ref
             ) do
        {:ok, auth.token_result.access_token}
      end
    end
  end

  defp credential_ref(%{"credential_ref" => credential_ref}) when is_map(credential_ref),
    do: {:ok, credential_ref}

  defp credential_ref(%{credential_ref: credential_ref}) when is_map(credential_ref),
    do: {:ok, credential_ref}

  defp credential_ref(_params), do: {:error, :credential_ref_required}

  defp scope_from_context(context) do
    case Map.get(context, :current_scope) || Map.get(context, "current_scope") do
      %Scope{} = scope ->
        {:ok, scope}

      _ ->
        scope_from_ids(context)
    end
  end

  defp scope_from_ids(context) do
    with {:ok, user_id} <- context_string(context, :user_id),
         {:ok, organization_id} <- context_string(context, :workos_organization_id),
         %User{} = user <- Repo.get(User, user_id) do
      {:ok, %Scope{user: user, actor: :user, organization_id: organization_id}}
    else
      nil -> {:error, :user_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp context_string(context, key) when is_map(context) and is_atom(key) do
    case context_value(context, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_context, key}}
    end
  end

  defp context_value(context, :project_id) do
    Map.get(context, :project_id) ||
      Map.get(context, "project_id") ||
      get_in(context, [:workflow, :project_id]) ||
      get_in(context, ["workflow", "project_id"]) ||
      get_in(context, [:metadata, :project_id]) ||
      get_in(context, ["metadata", "project_id"])
  end

  defp context_value(context, :workos_organization_id) do
    Map.get(context, :workos_organization_id) ||
      Map.get(context, "workos_organization_id") ||
      get_in(context, [:workflow, :workos_organization_id]) ||
      get_in(context, ["workflow", "workos_organization_id"]) ||
      get_in(context, [:metadata, :workos_organization_id]) ||
      get_in(context, ["metadata", "workos_organization_id"])
  end

  defp context_value(context, :user_id) do
    Map.get(context, :user_id) ||
      Map.get(context, "user_id") ||
      scope_user_id(Map.get(context, :current_scope) || Map.get(context, "current_scope"))
  end

  defp context_value(context, key),
    do: Map.get(context, key) || Map.get(context, Atom.to_string(key))

  defp scope_user_id(%Scope{user: %User{id: user_id}}), do: user_id
  defp scope_user_id(_scope), do: nil

  defp fetch_string(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_param, key}}
    end
  end

  defp encode_range(range) do
    URI.encode(range, &URI.char_unreserved?/1)
  end

  defp normalize_headers(row) do
    row
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      case cell_to_string(value) do
        "" -> "col_#{index + 1}"
        normalized -> normalized
      end
    end)
  end

  defp cell_to_string(nil), do: ""
  defp cell_to_string(value) when is_binary(value), do: value
  defp cell_to_string(value) when is_integer(value), do: Integer.to_string(value)

  defp cell_to_string(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 10)

  defp cell_to_string(value) when is_boolean(value), do: to_string(value)
  defp cell_to_string(value), do: Jason.encode!(value)

  defp sheet_names(%{"sheets" => sheets}) when is_list(sheets) do
    for %{"properties" => %{"title" => title}} <- sheets,
        is_binary(title),
        title != "" do
      title
    end
  end

  defp sheet_names(_body), do: []

  defp tables(%{"sheets" => sheets}) when is_list(sheets) do
    Enum.flat_map(sheets, &tables_for_sheet/1)
  end

  defp tables(_body), do: []

  defp tables_for_sheet(%{"properties" => properties, "tables" => sheet_tables})
       when is_map(properties) and is_list(sheet_tables) do
    Enum.flat_map(sheet_tables, &table_option(&1, properties))
  end

  defp tables_for_sheet(_sheet), do: []

  defp table_option(%{"tableId" => table_id} = table, properties) when is_binary(table_id) do
    [
      %{
        "id" => table_id,
        "label" => table_label(table, table_id),
        "name" => Map.get(table, "name"),
        "sheet_id" => Map.get(properties, "sheetId"),
        "sheet_name" => Map.get(properties, "title", ""),
        "range" => Map.get(table, "range"),
        "columns" => table_columns(table)
      }
    ]
  end

  defp table_option(_table, _properties), do: []

  defp table_label(%{"name" => name}, _table_id) when is_binary(name) and name != "", do: name
  defp table_label(_table, table_id), do: table_id

  defp table_columns(%{"columnProperties" => columns} = table) when is_list(columns) do
    case table_width(Map.get(table, "range")) do
      width when is_integer(width) and width > 0 ->
        columns_by_index =
          Map.new(columns, fn column -> {Map.get(column, "columnIndex"), column} end)

        for index <- 0..(width - 1) do
          table_column(Map.get(columns_by_index, index, %{"columnIndex" => index}), index)
        end

      _ ->
        columns
        |> Enum.sort_by(&(Map.get(&1, "columnIndex") || 0))
        |> Enum.with_index()
        |> Enum.map(fn {column, fallback_index} ->
          table_column(column, Map.get(column, "columnIndex") || fallback_index)
        end)
    end
  end

  defp table_columns(%{"range" => range}), do: range_columns(range)
  defp table_columns(_table), do: []

  defp enrich_table_header_rows(tables, spreadsheet_id, token) do
    Enum.map(tables, &enrich_table_header_row(&1, spreadsheet_id, token))
  end

  defp enrich_table_header_row(%{"columns" => columns} = table, spreadsheet_id, token)
       when is_list(columns) do
    if Enum.any?(columns, &generated_column_label?/1) do
      fetch_table_header_row(table, spreadsheet_id, token)
    else
      table
    end
  end

  defp enrich_table_header_row(table, _spreadsheet_id, _token), do: table

  defp fetch_table_header_row(table, spreadsheet_id, token) do
    with {:ok, range} <- table_header_range(table),
         {:ok, body} <-
           request(
             :get,
             "#{@sheets_base_url}/spreadsheets/#{spreadsheet_id}/values/#{encode_range(range)}",
             token: token,
             params: %{
               valueRenderOption: "FORMATTED_VALUE",
               dateTimeRenderOption: "FORMATTED_STRING"
             }
           ),
         [row | _] when is_list(row) <- Map.get(body, "values", []) do
      merge_table_header_row(table, row)
    else
      _ -> table
    end
  end

  defp generated_column_label?(%{"label" => "col"}), do: true

  defp generated_column_label?(%{"label" => label}) when is_binary(label),
    do: Regex.match?(~r/^col_\d+$/, label)

  defp generated_column_label?(_column), do: true

  defp table_header_range(%{
         "sheet_name" => sheet_name,
         "range" => %{
           "startRowIndex" => start_row_index,
           "startColumnIndex" => start_column_index,
           "endColumnIndex" => end_column_index
         }
       })
       when is_binary(sheet_name) and sheet_name != "" and is_integer(start_row_index) and
              is_integer(start_column_index) and is_integer(end_column_index) and
              end_column_index > start_column_index do
    row = start_row_index + 1
    start_column = a1_column(start_column_index)
    end_column = a1_column(end_column_index - 1)

    {:ok, "#{quote_sheet_name(sheet_name)}!#{start_column}#{row}:#{end_column}#{row}"}
  end

  defp table_header_range(_table), do: :error

  defp merge_table_header_row(%{"columns" => columns} = table, row)
       when is_list(columns) and is_list(row) do
    labels = header_value_labels(row, length(columns))

    columns =
      columns
      |> Enum.with_index()
      |> Enum.map(fn {column, index} ->
        case Enum.at(labels, index) do
          label when is_binary(label) ->
            column
            |> Map.put("id", label)
            |> Map.put("label", label)

          _ ->
            column
        end
      end)

    Map.put(table, "columns", columns)
  end

  defp merge_table_header_row(table, _row), do: table

  defp header_value_labels(row, width) do
    row
    |> Enum.take(width)
    |> Enum.map(&header_value_label/1)
    |> pad_to_width(width)
  end

  defp header_value_label(value) do
    case value |> cell_to_string() |> String.trim() do
      "" -> nil
      label -> label
    end
  end

  defp pad_to_width(values, width) do
    values ++ List.duplicate(nil, max(width - length(values), 0))
  end

  defp a1_column(index) when is_integer(index) and index >= 0 do
    a1_column(index + 1, "")
  end

  defp a1_column(0, acc), do: acc

  defp a1_column(index, acc) do
    remainder = rem(index - 1, 26)
    a1_column(div(index - 1, 26), <<65 + remainder>> <> acc)
  end

  defp table_column(column, index) do
    label = column_label(column, index)

    %{
      "id" => label,
      "label" => label,
      "index" => index,
      "type" => Map.get(column, "columnType")
    }
  end

  defp column_label(%{"columnName" => name}, index) when is_binary(name) do
    case String.trim(name) do
      "" -> nil_or_column_name(index)
      trimmed -> trimmed
    end
  end

  defp column_label(_column, index), do: nil_or_column_name(index)
  defp nil_or_column_name(nil), do: "col"
  defp nil_or_column_name(index), do: "col_#{index + 1}"

  defp table_width(%{"startColumnIndex" => start_index, "endColumnIndex" => end_index})
       when is_integer(start_index) and is_integer(end_index) and end_index > start_index do
    end_index - start_index
  end

  defp table_width(_range), do: nil

  defp range_columns(range) do
    case table_width(range) do
      width when is_integer(width) and width > 0 ->
        for index <- 0..(width - 1) do
          label = nil_or_column_name(index)

          %{
            "id" => label,
            "label" => label,
            "index" => index
          }
        end

      _ ->
        []
    end
  end

  defp row_data(rows) do
    Enum.map(rows, fn row ->
      %{
        values:
          Enum.map(row, fn value ->
            %{userEnteredValue: extended_value(value)}
          end)
      }
    end)
  end

  defp extended_value(nil), do: %{stringValue: ""}
  defp extended_value(value) when is_binary(value), do: %{stringValue: value}
  defp extended_value(value) when is_boolean(value), do: %{boolValue: value}
  defp extended_value(value) when is_integer(value), do: %{numberValue: value}
  defp extended_value(value) when is_float(value), do: %{numberValue: value}
  defp extended_value(value), do: %{stringValue: cell_to_string(value)}

  defp maybe_put_json(opts, nil), do: opts
  defp maybe_put_json(opts, json), do: Keyword.put(opts, :json, json)

  defp retry_after_ms(headers) do
    headers
    |> Enum.find_value(fn
      {"retry-after", value} -> parse_retry_after(value)
      {"Retry-After", value} -> parse_retry_after(value)
      _header -> nil
    end)
    |> case do
      nil -> :timer.minutes(1)
      ms -> ms
    end
  end

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> :timer.seconds(seconds)
      _ -> nil
    end
  end
end
