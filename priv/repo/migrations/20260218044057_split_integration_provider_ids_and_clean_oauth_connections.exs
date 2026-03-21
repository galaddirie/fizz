defmodule Fizz.Repo.Migrations.SplitIntegrationProviderIdsAndCleanOauthConnections do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE api_credentials
    SET provider = CASE provider
      WHEN 'github' THEN 'github_api_key'
      WHEN 'openai' THEN 'openai_api_key'
      WHEN 'anthropic' THEN 'anthropic_api_key'
      WHEN 'custom' THEN 'custom_api_key'
      ELSE provider
    END
    """)

    execute("DELETE FROM oauth_connections WHERE auth_method = 'api_key'")

    execute("""
    UPDATE oauth_connections
    SET provider = CASE provider
      WHEN 'github' THEN 'github_oauth'
      ELSE provider
    END
    """)

    drop_if_exists index(:oauth_connections, [:api_credential_id])

    execute(
      "ALTER TABLE oauth_connections DROP CONSTRAINT IF EXISTS oauth_connections_auth_method_api_credential_check"
    )

    execute(
      "ALTER TABLE oauth_connections DROP CONSTRAINT IF EXISTS oauth_connections_api_credential_id_fkey"
    )

    alter table(:oauth_connections) do
      remove :auth_method
      remove :api_credential_id
    end
  end

  def down do
    alter table(:oauth_connections) do
      add :auth_method, :string, null: false, default: "oauth"

      add :api_credential_id,
          references(:api_credentials, on_delete: :nilify_all, type: :binary_id)
    end

    create index(:oauth_connections, [:api_credential_id])

    execute("""
    ALTER TABLE oauth_connections
    ADD CONSTRAINT oauth_connections_auth_method_api_credential_check
    CHECK (
      (auth_method = 'oauth' AND api_credential_id IS NULL) OR
      (auth_method = 'api_key' AND api_credential_id IS NOT NULL)
    )
    """)

    execute("""
    UPDATE oauth_connections
    SET provider = CASE provider
      WHEN 'github_oauth' THEN 'github'
      ELSE provider
    END
    """)

    execute("""
    UPDATE api_credentials
    SET provider = CASE provider
      WHEN 'github_api_key' THEN 'github'
      WHEN 'openai_api_key' THEN 'openai'
      WHEN 'anthropic_api_key' THEN 'anthropic'
      WHEN 'custom_api_key' THEN 'custom'
      ELSE provider
    END
    """)
  end
end
