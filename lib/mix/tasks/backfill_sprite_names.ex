defmodule Mix.Tasks.BackfillSpriteNames do
  @shortdoc "Backfills sprite_name for existing workspaces"
  @moduledoc """
  Ensures every workspace has a corresponding row in the `sprites` table
  with its deterministic sprite name.

      mix backfill_sprite_names
  """

  use Mix.Task

  alias Fizz.Accounts.Workspace
  alias Fizz.Repo
  alias Fizz.Sprites.Name, as: SpriteName
  alias Fizz.Sprites.Sprite

  import Ecto.Query

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    workspaces =
      from(w in Workspace)
      |> Repo.all()

    total = length(workspaces)
    Mix.shell().info("Checking #{total} workspace(s) for missing sprite records.")

    Enum.each(workspaces, fn workspace ->
      tenant_id = "org:#{workspace.workos_organization_id}"
      sprite_name = SpriteName.sprite_name(tenant_id, workspace.slug)

      sprite =
        Repo.get_by(Sprite, name: sprite_name) ||
          %Sprite{name: sprite_name, workspace_id: workspace.id}

      case sprite
           |> Sprite.changeset(%{
             name: sprite_name,
             status: sprite.status || "available",
             workspace_id: workspace.id
           })
           |> Repo.insert_or_update() do
        {:ok, _sprite} ->
          Mix.shell().info("  #{workspace.slug} -> #{sprite_name}")

        {:error, reason} ->
          Mix.shell().error("  #{workspace.slug} failed: #{inspect(reason)}")
      end
    end)

    Mix.shell().info("Done.")
  end
end
