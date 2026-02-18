defmodule Fizz.Repo.Migrations.AddIntegrationCredentialsAndAuthMethod do
  use Ecto.Migration

  def change do
    create table(:integration_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false
      add :workos_organization_id, :string, null: false
      add :provider, :string, null: false
      add :provider_label, :string, null: false
      add :provider_custom_name, :string
      add :vault_object_id, :string, null: false
      add :vault_object_name, :string, null: false
      add :vault_version, :string
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:integration_credentials, [:workspace_id, :user_id, :provider],
             name: :integration_credentials_workspace_user_provider_index
           )

    create unique_index(:integration_credentials, [:vault_object_id])
    create unique_index(:integration_credentials, [:vault_object_name])
    create index(:integration_credentials, [:workspace_id, :provider])
    create index(:integration_credentials, [:user_id, :provider])
    create index(:integration_credentials, [:workos_organization_id])

    alter table(:integration_connections) do
      add :auth_method, :string, null: false, default: "oauth"

      add :credential_id,
          references(:integration_credentials, on_delete: :nilify_all, type: :binary_id)
    end

    create index(:integration_connections, [:credential_id])

    create constraint(
             :integration_connections,
             :integration_connections_auth_method_credential_check,
             check:
               "(auth_method = 'oauth' AND credential_id IS NULL) OR (auth_method = 'api_key' AND credential_id IS NOT NULL)"
           )
  end
end
