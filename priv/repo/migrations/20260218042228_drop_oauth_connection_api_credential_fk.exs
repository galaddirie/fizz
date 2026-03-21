defmodule Fizz.Repo.Migrations.DropOauthConnectionApiCredentialFk do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE oauth_connections DROP CONSTRAINT IF EXISTS oauth_connections_api_credential_id_fkey",
      """
      ALTER TABLE oauth_connections
      ADD CONSTRAINT oauth_connections_api_credential_id_fkey
      FOREIGN KEY (api_credential_id)
      REFERENCES api_credentials(id)
      ON DELETE SET NULL
      """
    )
  end
end
