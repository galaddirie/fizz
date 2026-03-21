defmodule Fizz.Repo.Migrations.MakeIntegrationCredentialsOrgScoped do
  use Ecto.Migration

  def change do
    drop_if_exists index(:integration_credentials, [:workspace_id, :provider])

    drop_if_exists unique_index(:integration_credentials, [:workspace_id, :user_id, :provider],
                     name: :integration_credentials_workspace_user_provider_index
                   )

    execute("ALTER TABLE integration_credentials DROP COLUMN IF EXISTS workspace_id")

    create unique_index(:integration_credentials, [:workos_organization_id, :user_id, :provider],
             name: :integration_credentials_org_user_provider_index
           )

    create index(:integration_credentials, [:workos_organization_id, :provider])
  end
end
