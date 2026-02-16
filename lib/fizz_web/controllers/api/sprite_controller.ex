defmodule FizzWeb.Api.SpriteController do
  use FizzWeb, :controller

  alias Fizz.Sprites
  alias FizzWeb.Api.Helpers

  plug FizzWeb.Plugs.RequireWorkspaceScope

  def index(conn, %{"workspace_id" => workspace_id}) do
    case Sprites.list_sprites(conn.assigns.current_scope, workspace_id) do
      {:ok, sprites} -> json(conn, %{data: Enum.map(sprites, &Helpers.sprite_json/1)})
      {:error, reason} -> Helpers.error(conn, reason)
    end
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    case Sprites.create_sprite(conn.assigns.current_scope, workspace_id, params) do
      {:ok, sprite} ->
        conn
        |> put_status(:created)
        |> json(%{data: Helpers.sprite_json(sprite)})

      {:error, reason} ->
        Helpers.error(conn, reason)
    end
  end

  def show(conn, %{"workspace_id" => workspace_id, "sprite_id" => sprite_id}) do
    case Sprites.get_sprite(conn.assigns.current_scope, workspace_id, sprite_id) do
      {:ok, sprite} -> json(conn, %{data: Helpers.sprite_json(sprite)})
      {:error, reason} -> Helpers.error(conn, reason)
    end
  end

  def update(conn, %{"workspace_id" => workspace_id, "sprite_id" => sprite_id} = params) do
    case Sprites.update_sprite(conn.assigns.current_scope, workspace_id, sprite_id, params) do
      {:ok, sprite} -> json(conn, %{data: Helpers.sprite_json(sprite)})
      {:error, reason} -> Helpers.error(conn, reason)
    end
  end

  def delete(conn, %{"workspace_id" => workspace_id, "sprite_id" => sprite_id}) do
    case Sprites.delete_sprite(conn.assigns.current_scope, workspace_id, sprite_id) do
      {:ok, sprite} -> json(conn, %{data: Helpers.sprite_json(sprite)})
      {:error, reason} -> Helpers.error(conn, reason)
    end
  end
end
