defmodule FizzWeb.Plugs.RequireProjectScope do
  @moduledoc """
  Resolves and assigns a project-aware scope for API requests.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias Fizz.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    project_id = conn.params["project_id"]
    current_scope = conn.assigns[:current_scope]

    case Accounts.build_scope_for_project(current_scope, project_id) do
      {:ok, resolved_project_scope} ->
        conn
        |> assign(:resolve_project_scope, resolved_project_scope)
        |> assign(:project_id, project_id)

      {:error, :project_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "project_not_found"})
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
