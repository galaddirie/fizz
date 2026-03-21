defmodule Fizz.Repo.Migrations.MakeIntegrationConnectionsOrgScoped do
  use Ecto.Migration

  def up do
    drop_if_exists index(:integration_connections, [:workspace_id, :provider])
    drop_if_exists index(:integration_connections, [:workspace_id, :user_id, :provider])

    alter table(:integration_connections) do
      add :workos_organization_id, :string
    end

    execute("""
    UPDATE integration_connections AS connection
    SET workos_organization_id = workspace.workos_organization_id
    FROM workspaces AS workspace
    WHERE connection.workspace_id = workspace.id
      AND connection.workos_organization_id IS NULL
    """)

    execute("""
    ALTER TABLE integration_connections
    ALTER COLUMN workos_organization_id SET NOT NULL
    """)

    alter table(:integration_connections) do
      remove :workspace_id
    end

    create unique_index(:integration_connections, [:workos_organization_id, :user_id, :provider],
             name: :integration_connections_org_user_provider_index
           )

    create index(:integration_connections, [:workos_organization_id, :provider])
  end

  def down do
    drop_if_exists index(:integration_connections, [:workos_organization_id, :provider])

    drop_if_exists unique_index(
                     :integration_connections,
                     [:workos_organization_id, :user_id, :provider],
                     name: :integration_connections_org_user_provider_index
                   )

    alter table(:integration_connections) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id)
      remove :workos_organization_id
    end

    create unique_index(:integration_connections, [:workspace_id, :user_id, :provider])
    create index(:integration_connections, [:workspace_id, :provider])
  end
end
