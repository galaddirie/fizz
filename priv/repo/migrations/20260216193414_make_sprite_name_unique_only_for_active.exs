defmodule Fizz.Repo.Migrations.MakeSpriteNameUniqueOnlyForActive do
  use Ecto.Migration

  def change do
    drop unique_index(:sprites, [:workspace_id, :name])

    create unique_index(:sprites, [:workspace_id, :name],
      where: "deleted_at IS NULL",
      name: :sprites_workspace_id_name_index
    )
  end
end
