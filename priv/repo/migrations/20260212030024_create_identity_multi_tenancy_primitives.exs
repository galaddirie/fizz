defmodule Fizz.Repo.Migrations.CreateIdentityMultiTenancyPrimitives do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :workos_user_id, :string
    end

    create unique_index(:users, [:workos_user_id], where: "workos_user_id IS NOT NULL")

    create table(:organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :workos_organization_id, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organizations, [:slug])

    create unique_index(:organizations, [:workos_organization_id],
             where: "workos_organization_id IS NOT NULL"
           )

    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:workspaces, [:organization_id])
    create unique_index(:workspaces, [:organization_id, :slug])

    create table(:organization_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false
      add :role, :string, null: false, default: "member"
      add :workos_organization_membership_id, :string

      timestamps(type: :utc_datetime)
    end

    create index(:organization_memberships, [:user_id])
    create unique_index(:organization_memberships, [:organization_id, :user_id])

    create unique_index(
             :organization_memberships,
             [:workos_organization_membership_id],
             where: "workos_organization_membership_id IS NOT NULL"
           )

    create table(:workspace_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false
      add :role, :string, null: false, default: "viewer"
      add :access_purpose, :string

      timestamps(type: :utc_datetime)
    end

    create index(:workspace_memberships, [:user_id])
    create unique_index(:workspace_memberships, [:workspace_id, :user_id])
  end
end
