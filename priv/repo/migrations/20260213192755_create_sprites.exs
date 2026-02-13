defmodule Fizz.Repo.Migrations.CreateSprites do
  use Ecto.Migration

  def change do
    create table(:sprites) do
      add :name, :string, null: false
      add :status, :string, null: false, default: "available"

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sprites, [:name])
    create index(:sprites, [:workspace_id])
  end
end
