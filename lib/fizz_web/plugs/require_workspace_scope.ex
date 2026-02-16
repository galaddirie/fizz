defmodule FizzWeb.Plugs.RequireWorkspaceScope do
  @moduledoc """
  Resolves and assigns a workspace-aware scope for API requests.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias Fizz.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    workspace_id = conn.params["workspace_id"]
    current_scope = conn.assigns[:current_scope]

    case Accounts.build_scope_for_workspace(current_scope, workspace_id) do
      {:ok, workspace_scope} ->
        conn
        |> assign(:workspace_scope, workspace_scope)
        |> assign(:workspace_id, workspace_id)

      {:error, :workspace_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "workspace_not_found"})
        |> halt()

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden"})
        |> halt()

      {:error, :unauthenticated} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthenticated"})
        |> halt()

      {:error, _reason} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden"})
        |> halt()
    end
  end
end
