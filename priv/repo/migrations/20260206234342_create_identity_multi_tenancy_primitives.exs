defmodule Fizz.Repo.Migrations.CreateIdentityMultiTenancyPrimitives do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :workos_user_id, :string
    end

    create unique_index(:users, [:workos_user_id], where: "workos_user_id IS NOT NULL")

    create table(:tenants) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :isolation_level, :string, null: false, default: "hard"
      add :workos_organization_id, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tenants, [:slug])

    create unique_index(:tenants, [:workos_organization_id],
             where: "workos_organization_id IS NOT NULL"
           )

    create table(:workspaces) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :string
      add :isolation_level, :string, null: false, default: "firm"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:workspaces, [:tenant_id])
    create unique_index(:workspaces, [:tenant_id, :slug])

    create table(:tenant_memberships) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"
      add :workos_organization_membership_id, :string

      timestamps(type: :utc_datetime)
    end

    create index(:tenant_memberships, [:user_id])
    create unique_index(:tenant_memberships, [:tenant_id, :user_id])

    create unique_index(
             :tenant_memberships,
             [:workos_organization_membership_id],
             where: "workos_organization_membership_id IS NOT NULL"
           )

    create table(:workspace_memberships) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "viewer"
      add :access_purpose, :string

      timestamps(type: :utc_datetime)
    end

    create index(:workspace_memberships, [:user_id])
    create unique_index(:workspace_memberships, [:workspace_id, :user_id])
  end
end
