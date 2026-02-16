defmodule FizzWeb.Api.IntegrationController do
  use FizzWeb, :controller

  alias Fizz.Integrations
  alias FizzWeb.Api.Helpers

  plug FizzWeb.Plugs.RequireWorkspaceScope

  def status(conn, %{"workspace_id" => workspace_id, "provider" => provider}) do
    case Integrations.check_and_sync_connection(
           conn.assigns.current_scope,
           workspace_id,
           provider
         ) do
      {:ok, connection} ->
        json(conn, %{data: connection_json(connection)})

      {:error, :unknown_provider} ->
        conn |> put_status(:not_found) |> json(%{error: "unknown_provider"})

      {:error, reason} ->
        Helpers.error(conn, reason)
    end
  end

  def repos(conn, %{"workspace_id" => workspace_id, "provider" => provider} = params) do
    opts = [
      per_page: params["per_page"] || 30,
      page: params["page"] || 1,
      sort: params["sort"] || "updated"
    ]

    case Integrations.list_repos(conn.assigns.current_scope, workspace_id, provider, opts) do
      {:ok, repos} ->
        json(conn, %{data: repos})

      {:error, :unknown_provider} ->
        conn |> put_status(:not_found) |> json(%{error: "unknown_provider"})

      {:error, reason} ->
        Helpers.error(conn, reason)
    end
  end

  def create_pr(conn, %{"workspace_id" => workspace_id, "provider" => provider} = params) do
    case Integrations.create_pull_request(
           conn.assigns.current_scope,
           workspace_id,
           provider,
           params
         ) do
      {:ok, pr} ->
        conn |> put_status(:created) |> json(%{data: pr})

      {:error, :unknown_provider} ->
        conn |> put_status(:not_found) |> json(%{error: "unknown_provider"})

      {:error, reason} ->
        Helpers.error(conn, reason)
    end
  end

  defp connection_json(connection) do
    %{
      id: connection.id,
      provider: connection.provider,
      status: to_string(connection.status),
      scopes: connection.scopes,
      missing_scopes: connection.missing_scopes,
      provider_metadata: connection.provider_metadata,
      last_token_fetch_at: connection.last_token_fetch_at,
      last_error: connection.last_error,
      disconnected_at: connection.disconnected_at,
      inserted_at: connection.inserted_at,
      updated_at: connection.updated_at
    }
  end
end
