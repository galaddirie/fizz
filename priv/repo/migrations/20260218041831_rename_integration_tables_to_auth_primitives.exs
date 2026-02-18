defmodule Fizz.Repo.Migrations.RenameIntegrationTablesToAuthPrimitives do
  use Ecto.Migration

  def up do
    rename table(:integration_credentials), to: table(:api_credentials)
    rename table(:integration_connections), to: table(:oauth_connections)
    rename table(:oauth_connections), :credential_id, to: :api_credential_id

    execute(
      "ALTER TABLE api_credentials RENAME CONSTRAINT integration_credentials_user_id_fkey TO api_credentials_user_id_fkey"
    )

    execute(
      "ALTER TABLE oauth_connections RENAME CONSTRAINT integration_connections_user_id_fkey TO oauth_connections_user_id_fkey"
    )

    execute(
      "ALTER TABLE oauth_connections RENAME CONSTRAINT integration_connections_credential_id_fkey TO oauth_connections_api_credential_id_fkey"
    )

    execute(
      "ALTER TABLE oauth_connections RENAME CONSTRAINT integration_connections_auth_method_credential_check TO oauth_connections_auth_method_api_credential_check"
    )

    execute(
      "ALTER INDEX IF EXISTS integration_credentials_org_user_provider_index RENAME TO api_credentials_org_user_provider_index"
    )

    execute(
      "ALTER INDEX IF EXISTS integration_credentials_vault_object_id_index RENAME TO api_credentials_vault_object_id_index"
    )

    execute(
      "ALTER INDEX IF EXISTS integration_credentials_vault_object_name_index RENAME TO api_credentials_vault_object_name_index"
    )

    execute(
      "ALTER INDEX IF EXISTS integration_credentials_user_id_provider_index RENAME TO api_credentials_user_id_provider_index"
    )

    execute(
      "ALTER INDEX IF EXISTS integration_credentials_workos_organization_id_index RENAME TO api_credentials_workos_organization_id_index"
    )

    execute(
      "ALTER INDEX IF EXISTS integration_credentials_workos_organization_id_provider_index RENAME TO api_credentials_workos_organization_id_provider_index"
    )

    execute(
      "ALTER INDEX IF EXISTS integration_connections_org_user_provider_index RENAME TO oauth_connections_org_user_provider_index"
    )

    execute(
      "ALTER INDEX IF EXISTS integration_connections_user_id_provider_index RENAME TO oauth_connections_user_id_provider_index"
    )

    execute(
      "ALTER INDEX IF EXISTS integration_connections_credential_id_index RENAME TO oauth_connections_api_credential_id_index"
    )

    execute(
      "ALTER INDEX IF EXISTS integration_connections_workos_organization_id_provider_index RENAME TO oauth_connections_workos_organization_id_provider_index"
    )
  end

  def down do
    execute(
      "ALTER INDEX IF EXISTS oauth_connections_workos_organization_id_provider_index RENAME TO integration_connections_workos_organization_id_provider_index"
    )

    execute(
      "ALTER INDEX IF EXISTS oauth_connections_api_credential_id_index RENAME TO integration_connections_credential_id_index"
    )

    execute(
      "ALTER INDEX IF EXISTS oauth_connections_user_id_provider_index RENAME TO integration_connections_user_id_provider_index"
    )

    execute(
      "ALTER INDEX IF EXISTS oauth_connections_org_user_provider_index RENAME TO integration_connections_org_user_provider_index"
    )

    execute(
      "ALTER INDEX IF EXISTS api_credentials_workos_organization_id_provider_index RENAME TO integration_credentials_workos_organization_id_provider_index"
    )

    execute(
      "ALTER INDEX IF EXISTS api_credentials_workos_organization_id_index RENAME TO integration_credentials_workos_organization_id_index"
    )

    execute(
      "ALTER INDEX IF EXISTS api_credentials_user_id_provider_index RENAME TO integration_credentials_user_id_provider_index"
    )

    execute(
      "ALTER INDEX IF EXISTS api_credentials_vault_object_name_index RENAME TO integration_credentials_vault_object_name_index"
    )

    execute(
      "ALTER INDEX IF EXISTS api_credentials_vault_object_id_index RENAME TO integration_credentials_vault_object_id_index"
    )

    execute(
      "ALTER INDEX IF EXISTS api_credentials_org_user_provider_index RENAME TO integration_credentials_org_user_provider_index"
    )

    execute(
      "ALTER TABLE oauth_connections RENAME CONSTRAINT oauth_connections_auth_method_api_credential_check TO integration_connections_auth_method_credential_check"
    )

    execute(
      "ALTER TABLE oauth_connections RENAME CONSTRAINT oauth_connections_api_credential_id_fkey TO integration_connections_credential_id_fkey"
    )

    execute(
      "ALTER TABLE oauth_connections RENAME CONSTRAINT oauth_connections_user_id_fkey TO integration_connections_user_id_fkey"
    )

    execute(
      "ALTER TABLE api_credentials RENAME CONSTRAINT api_credentials_user_id_fkey TO integration_credentials_user_id_fkey"
    )

    rename table(:oauth_connections), :api_credential_id, to: :credential_id
    rename table(:oauth_connections), to: table(:integration_connections)
    rename table(:api_credentials), to: table(:integration_credentials)
  end
end
