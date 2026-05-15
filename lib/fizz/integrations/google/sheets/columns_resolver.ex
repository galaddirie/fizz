defmodule Fizz.Integrations.Google.Sheets.ColumnsResolver do
  @moduledoc """
  Resolves Google Sheets table names or the live header row of a selected table
  so the editor can enhance the "Row Values" mapper when schema information is
  available.

  Reads `spreadsheet_id`, `sheet_name`, optional `header_row`, and an optional
  `credential_ref` from the frontend payload (merged into `args.params` by the
  resolver dispatch). When the field's `credential_ref` is still a slot
  declaration (not yet bound to a real credential), falls back to the editor
  user's most recent Google OAuth connection so the preview still works.

  Returns `{:ok, []}` for "not enough info yet" conditions (so the UI degrades
  gracefully while the author is still typing). Returns `{:error, reason}` for
  actionable failures (e.g. API call failed, no Google credential connected)
  so the UI can surface a specific message.
  """

  require Logger

  @behaviour Fizz.Steps.Resolver

  alias Fizz.Accounts.Scope
  alias Fizz.Accounts.ExternalAuth
  alias Fizz.Integrations.CredentialRef
  alias Fizz.Integrations.Google.Sheets.Client
  alias Fizz.Integrations.Providers.GoogleOAuth

  @impl true
  def resolve(%{params: params, context: context}) do
    case resolver_mode(params) do
      "sheets" -> resolve_sheets(params, context)
      "tables" -> resolve_tables(params, context)
      _ -> resolve_columns(params, context)
    end
  end

  defp resolve_columns(params, context) do
    with {:ok, spreadsheet_id} <- fetch_string(params, "spreadsheet_id"),
         {:ok, sheet_name} <- fetch_string(params, "sheet_name"),
         {:ok, scope} <- fetch_scope(context),
         {:ok, project_id} <- fetch_project_id(context) do
      case resolve_credential_ref(params, scope, project_id) do
        {:ok, credential_ref} ->
          fetch_columns(
            spreadsheet_id,
            sheet_name,
            header_row_param(params),
            credential_ref,
            scope,
            project_id
          )

        :error ->
          {:error, :no_google_credential}
      end
    else
      _ -> {:ok, []}
    end
  end

  defp resolve_sheets(params, context) do
    with {:ok, spreadsheet_id} <- fetch_string(params, "spreadsheet_id"),
         {:ok, scope} <- fetch_scope(context),
         {:ok, project_id} <- fetch_project_id(context) do
      case resolve_credential_ref(params, scope, project_id) do
        {:ok, credential_ref} ->
          fetch_sheets(spreadsheet_id, credential_ref, scope, project_id)

        :error ->
          {:error, :no_google_credential}
      end
    else
      _ -> {:ok, []}
    end
  end

  defp resolve_tables(params, context) do
    with {:ok, spreadsheet_id} <- fetch_string(params, "spreadsheet_id"),
         {:ok, scope} <- fetch_scope(context),
         {:ok, project_id} <- fetch_project_id(context) do
      case resolve_credential_ref(params, scope, project_id) do
        {:ok, credential_ref} ->
          fetch_tables(spreadsheet_id, credential_ref, scope, project_id)

        :error ->
          {:error, :no_google_credential}
      end
    else
      _ -> {:ok, []}
    end
  end

  defp fetch_sheets(spreadsheet_id, credential_ref, scope, project_id) do
    client_params = %{
      "spreadsheet_id" => spreadsheet_id,
      "credential_ref" => credential_ref
    }

    client_context = %{
      current_scope: scope,
      project_id: project_id
    }

    case Client.get_sheet_names(client_params, client_context) do
      {:ok, names} ->
        {:ok, Enum.map(names, &%{"id" => &1, "label" => &1})}

      {:backoff, reason} ->
        Logger.warning(
          "Google Sheets columns resolver: backoff fetching sheets " <>
            "(spreadsheet=#{spreadsheet_id}): #{inspect(reason)}"
        )

        {:error, :rate_limited}

      {:error, %{status: 401}} ->
        {:error, :unauthorized}

      {:error, %{status: 403}} ->
        {:error, :forbidden}

      {:error, %{status: 404}} ->
        {:error, :spreadsheet_not_found}

      {:error, reason} ->
        Logger.warning(
          "Google Sheets columns resolver: error fetching sheets " <>
            "(spreadsheet=#{spreadsheet_id}): #{inspect(reason)}"
        )

        {:error, "fetch_failed: #{summarize_reason(reason)}"}
    end
  end

  defp fetch_tables(spreadsheet_id, credential_ref, scope, project_id) do
    client_params = %{
      "spreadsheet_id" => spreadsheet_id,
      "credential_ref" => credential_ref
    }

    client_context = %{
      current_scope: scope,
      project_id: project_id
    }

    case Client.get_tables(client_params, client_context) do
      {:ok, tables} ->
        {:ok, tables}

      {:backoff, reason} ->
        Logger.warning(
          "Google Sheets columns resolver: backoff fetching tables " <>
            "(spreadsheet=#{spreadsheet_id}): #{inspect(reason)}"
        )

        {:error, :rate_limited}

      {:error, %{status: 401}} ->
        {:error, :unauthorized}

      {:error, %{status: 403}} ->
        {:error, :forbidden}

      {:error, %{status: 404}} ->
        {:error, :spreadsheet_not_found}

      {:error, reason} ->
        Logger.warning(
          "Google Sheets columns resolver: error fetching tables " <>
            "(spreadsheet=#{spreadsheet_id}): #{inspect(reason)}"
        )

        {:error, "fetch_failed: #{summarize_reason(reason)}"}
    end
  end

  defp fetch_columns(spreadsheet_id, sheet_name, header_row, credential_ref, scope, project_id) do
    client_params = %{
      "spreadsheet_id" => spreadsheet_id,
      "credential_ref" => credential_ref
    }

    client_context = %{
      current_scope: scope,
      project_id: project_id
    }

    case Client.get_headers(client_params, client_context,
           sheet_name: sheet_name,
           header_row: header_row
         ) do
      {:ok, []} ->
        {:ok, []}

      {:ok, headers} ->
        {:ok, Enum.map(headers, &%{"id" => &1, "label" => &1})}

      {:backoff, reason} ->
        Logger.warning(
          "Google Sheets columns resolver: backoff fetching headers " <>
            "(spreadsheet=#{spreadsheet_id}, sheet=#{sheet_name}): #{inspect(reason)}"
        )

        {:error, :rate_limited}

      {:error, %{status: 401}} ->
        {:error, :unauthorized}

      {:error, %{status: 403}} ->
        {:error, :forbidden}

      {:error, %{status: 404}} ->
        {:error, :spreadsheet_not_found}

      {:error, %{status: 400, body: body}} ->
        Logger.warning(
          "Google Sheets columns resolver: 400 fetching headers " <>
            "(spreadsheet=#{spreadsheet_id}, sheet=#{sheet_name}): #{inspect(body)}"
        )

        {:error, :invalid_range_or_sheet}

      {:error, reason} ->
        Logger.warning(
          "Google Sheets columns resolver: error fetching headers " <>
            "(spreadsheet=#{spreadsheet_id}, sheet=#{sheet_name}): #{inspect(reason)}"
        )

        {:error, "fetch_failed: #{summarize_reason(reason)}"}
    end
  end

  defp summarize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp summarize_reason({tag, inner}) when is_atom(tag), do: "#{tag}: #{inspect(inner)}"

  defp summarize_reason(%{status: status, body: body}) do
    "http_#{status} #{summarize_body(body)}"
  end

  defp summarize_reason(%{status: status}), do: "http_#{status}"
  defp summarize_reason(reason), do: inspect(reason) |> String.slice(0, 200)

  defp summarize_body(%{"error" => %{"message" => message}}) when is_binary(message),
    do: message

  defp summarize_body(body), do: inspect(body) |> String.slice(0, 200)

  defp resolver_mode(params) when is_map(params) do
    case Map.get(params, "mode") || Map.get(params, :mode) do
      value when is_binary(value) -> value
      _ -> "columns"
    end
  end

  defp resolver_mode(_params), do: "columns"

  defp fetch_string(params, key) when is_map(params) do
    case Map.get(params, key) || fetch_known_atom(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> :error
          trimmed -> {:ok, trimmed}
        end

      _ ->
        :error
    end
  end

  defp fetch_string(_params, _key), do: :error

  defp fetch_known_atom(params, "spreadsheet_id"), do: Map.get(params, :spreadsheet_id)
  defp fetch_known_atom(params, "sheet_name"), do: Map.get(params, :sheet_name)
  defp fetch_known_atom(_params, _key), do: nil

  defp fetch_scope(context) when is_map(context) do
    case Map.get(context, :current_scope) || Map.get(context, "current_scope") do
      %Scope{} = scope -> {:ok, scope}
      _ -> :error
    end
  end

  defp fetch_scope(_context), do: :error

  defp fetch_project_id(context) when is_map(context) do
    case Map.get(context, :project_id) || Map.get(context, "project_id") do
      project_id when is_binary(project_id) and project_id != "" -> {:ok, project_id}
      _ -> :error
    end
  end

  defp fetch_project_id(_context), do: :error

  defp resolve_credential_ref(params, scope, project_id) do
    case Map.get(params, "credential_ref") || Map.get(params, :credential_ref) do
      ref when is_map(ref) ->
        with {:ok, normalized} <- CredentialRef.normalize(ref),
             :ok <- ensure_current_user_ref(normalized, scope) do
          {:ok, normalized}
        else
          {:error, _} -> fallback_credential_ref(scope, project_id)
        end

      _ ->
        fallback_credential_ref(scope, project_id)
    end
  end

  defp ensure_current_user_ref(ref, %Scope{user: %{id: user_id}}) when is_binary(user_id) do
    CredentialRef.ensure_owner(ref, user_id)
  end

  defp ensure_current_user_ref(_ref, _scope), do: {:error, :scope_user_required}

  defp fallback_credential_ref(%Scope{organization_id: organization_id} = scope, _project_id)
       when is_binary(organization_id) do
    ExternalAuth.list_credential_options(scope, organization_id,
      provider_filter: [GoogleOAuth.provider_id()],
      auth_types: [:oauth]
    )
    |> case do
      {:ok, options} ->
        options
        |> Enum.filter(&owned_by_scope?(&1, scope))
        |> case do
          [option | _] -> CredentialRef.normalize(option)
          [] -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp fallback_credential_ref(%Scope{} = _scope, _project_id), do: :error

  defp owned_by_scope?(option, %Scope{user: %{id: user_id}}) when is_map(option) do
    (Map.get(option, "owner_user_id") || Map.get(option, :owner_user_id)) == user_id
  end

  defp owned_by_scope?(_option, _scope), do: false

  defp header_row_param(params) do
    case Map.get(params, "header_row") || Map.get(params, :header_row) do
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) -> parse_positive_integer(value, 1)
      _ -> 1
    end
  end

  defp parse_positive_integer(value, default) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> default
    end
  end
end
