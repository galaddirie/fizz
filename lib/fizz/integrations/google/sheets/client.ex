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

  defp request(method, url, opts) do
    req_opts =
      [
        method: method,
        url: url,
        headers: [{"authorization", "Bearer #{Keyword.fetch!(opts, :token)}"}],
        params: Keyword.get(opts, :params, %{})
      ]
      |> maybe_put_json(Keyword.get(opts, :json))

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
    with {:ok, scope} <- scope_from_context(context),
         {:ok, project_id} <- context_string(context, :project_id) do
      case Map.get(params, "credential_ref") do
        credential_ref when is_map(credential_ref) ->
          with {:ok, auth} <-
                 Integrations.resolve_auth_for_execution(
                   scope,
                   project_id,
                   GoogleOAuth.provider_id(),
                   credential_ref
                 ) do
            {:ok, auth.token_result.access_token}
          end

        _ ->
          with {:ok, token_result} <-
                 Integrations.fetch_token_for_execution(
                   scope,
                   project_id,
                   GoogleOAuth.provider_id()
                 ) do
            {:ok, token_result.access_token}
          end
      end
    end
  end

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
