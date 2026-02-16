defmodule FizzWeb.Api.SpriteCheckpointController do
  use FizzWeb, :controller

  alias Fizz.Sprites
  alias FizzWeb.Api.Helpers

  plug FizzWeb.Plugs.RequireWorkspaceScope

  def index(conn, %{"workspace_id" => workspace_id, "sprite_id" => sprite_id}) do
    case Sprites.list_sprite_checkpoints(conn.assigns.current_scope, workspace_id, sprite_id) do
      {:ok, checkpoints} -> json(conn, %{data: checkpoints})
      {:error, reason} -> Helpers.error(conn, reason)
    end
  end

  def create(conn, %{"workspace_id" => workspace_id, "sprite_id" => sprite_id} = params) do
    case Sprites.capture_checkpoint(conn.assigns.current_scope, workspace_id, sprite_id, params) do
      {:ok, checkpoint} ->
        conn
        |> put_status(:created)
        |> json(%{data: checkpoint})

      {:error, reason} ->
        Helpers.error(conn, reason)
    end
  end

  def restore(conn, %{
        "workspace_id" => workspace_id,
        "sprite_id" => sprite_id,
        "checkpoint_id" => checkpoint_id
      }) do
    case Sprites.restore_checkpoint(
           conn.assigns.current_scope,
           workspace_id,
           sprite_id,
           checkpoint_id
         ) do
      {:ok, messages} -> json(conn, %{data: messages})
      {:error, reason} -> Helpers.error(conn, reason)
    end
  end
end
