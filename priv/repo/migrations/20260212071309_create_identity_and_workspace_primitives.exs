defmodule Fizz.Repo.Migrations.CreateIdentityAndWorkspacePrimitives do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS citext", "")

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :confirmed_at, :utc_datetime
      add :workos_user_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:workos_user_id], where: "workos_user_id IS NOT NULL")

    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :string
      add :metadata, :map, null: false, default: %{}
      add :workos_organization_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workspaces, [:workos_organization_id])

    create unique_index(:workspaces, [:workos_organization_id, :slug],
             name: :workspaces_workos_organization_id_slug_index
           )

    create table(:workspace_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false
      add :role, :string, null: false, default: "viewer"
      add :access_purpose, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workspace_memberships, [:workspace_id])
    create index(:workspace_memberships, [:user_id])
    create unique_index(:workspace_memberships, [:workspace_id, :user_id])
  end
end
