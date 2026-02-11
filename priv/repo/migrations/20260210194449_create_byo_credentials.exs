defmodule Fizz.Repo.Migrations.CreateByoCredentials do
  use Ecto.Migration

  def change do
    create table(:byo_credentials) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :tenant_id, references(:tenants, on_delete: :delete_all)
      add :provider, :string, null: false
      add :label, :string, null: false
      add :vault_object_id, :string, null: false
      add :status, :string, null: false, default: "active"
      add :revoked_at, :utc_datetime
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:byo_credentials, [:user_id])
    create index(:byo_credentials, [:tenant_id])
    create index(:byo_credentials, [:user_id, :provider])
    create unique_index(:byo_credentials, [:vault_object_id])
  end
end
