defmodule FizzWeb.Api.SpriteConsoleController do
  use FizzWeb, :controller

  alias Fizz.Sprites
  alias FizzWeb.Api.Helpers

  plug FizzWeb.Plugs.RequireWorkspaceScope

  def create(conn, %{"workspace_id" => workspace_id, "sprite_id" => sprite_id} = params) do
    case Sprites.open_console(conn.assigns.current_scope, workspace_id, sprite_id, params) do
      {:ok, console_session} ->
        conn
        |> put_status(:created)
        |> json(%{data: Helpers.console_json(console_session)})

      {:error, reason} ->
        Helpers.error(conn, reason)
    end
  end

  def delete(conn, %{
        "workspace_id" => workspace_id,
        "sprite_id" => sprite_id,
        "console_id" => console_id
      }) do
    case Sprites.close_console(conn.assigns.current_scope, workspace_id, sprite_id, console_id) do
      {:ok, console_session} -> json(conn, %{data: Helpers.console_json(console_session)})
      {:error, reason} -> Helpers.error(conn, reason)
    end
  end
end
