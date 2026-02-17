defmodule Fizz.Repo.Migrations.RemoveLocalOrganizationsAndMemberships do
  use Ecto.Migration

  def up do
    alter table(:workspaces) do
      add :workos_organization_id, :string
    end

    execute("""
    UPDATE workspaces AS w
    SET workos_organization_id = COALESCE(o.workos_organization_id, o.id::text)
    FROM organizations AS o
    WHERE w.organization_id = o.id
    """)

    drop_if_exists constraint(:workspaces, "workspaces_organization_id_fkey")
    drop_if_exists index(:workspaces, [:organization_id])
    drop_if_exists index(:workspaces, [:organization_id, :slug])

    alter table(:workspaces) do
      remove :organization_id
      modify :workos_organization_id, :string, null: false
    end

    create index(:workspaces, [:workos_organization_id])

    create unique_index(:workspaces, [:workos_organization_id, :slug],
             name: :workspaces_workos_organization_id_slug_index
           )

    drop_if_exists table(:organization_memberships)
    drop_if_exists table(:organizations)
  end

  def down do
    raise "This migration is irreversible"
  end
end
