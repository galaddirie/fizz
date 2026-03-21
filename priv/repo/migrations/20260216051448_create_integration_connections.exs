defmodule Fizz.Repo.Migrations.CreateIntegrationConnections do
  use Ecto.Migration

  def change do
    create table(:integration_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false

      add :provider, :string, null: false
      add :status, :string, null: false, default: "active"
      add :scopes, {:array, :string}, default: []
      add :missing_scopes, {:array, :string}, default: []
      add :provider_metadata, :map, default: %{}
      add :last_token_fetch_at, :utc_datetime_usec
      add :last_error, :string
      add :disconnected_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:integration_connections, [:workspace_id, :user_id, :provider])
    create index(:integration_connections, [:workspace_id, :provider])
    create index(:integration_connections, [:user_id, :provider])
  end
end
