defmodule Fizz.Repo.Migrations.CreateSpritesManagementTables do
  use Ecto.Migration

  def change do
    create table(:managed_sprites, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :sprite_name, :string, null: false
      add :display_name, :string, null: false
      add :description, :string
      add :status, :string, null: false, default: "pending"
      add :url, :string
      add :url_auth_mode, :string, null: false, default: "bearer"
      add :metadata, :map, null: false, default: %{}
      add :archived_at, :utc_datetime_usec
      add :deleted_at, :utc_datetime_usec
      add :last_reconciled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:managed_sprites, [:workspace_id])
    create index(:managed_sprites, [:workspace_id, :status])
    create unique_index(:managed_sprites, [:sprite_name])

    create table(:sprite_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :managed_sprite_id,
          references(:managed_sprites, on_delete: :delete_all, type: :binary_id),
          null: false

      add :owner_user_id, references(:users, on_delete: :delete_all, type: :binary_id),
        null: false

      add :provider_session_id, :string
      add :interactive_command, :string, null: false
      add :tty, :boolean, null: false, default: true
      add :status, :string, null: false, default: "starting"
      add :idle_timeout_seconds, :integer
      add :last_activity_at, :utc_datetime_usec
      add :closed_reason, :string
      add :exit_code, :integer
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sprite_sessions, [:managed_sprite_id])
    create index(:sprite_sessions, [:managed_sprite_id, :status])
    create index(:sprite_sessions, [:owner_user_id])

    create unique_index(:sprite_sessions, [:provider_session_id],
             where: "provider_session_id IS NOT NULL"
           )

    create table(:sprite_commands, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :managed_sprite_id,
          references(:managed_sprites, on_delete: :delete_all, type: :binary_id),
          null: false

      add :actor_user_id, references(:users, on_delete: :delete_all, type: :binary_id),
        null: false

      add :command, :string, null: false
      add :args, {:array, :string}, null: false, default: []
      add :cwd, :string
      add :mode, :string, null: false, default: "oneshot"
      add :status, :string, null: false, default: "running"
      add :exit_code, :integer
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sprite_commands, [:managed_sprite_id])
    create index(:sprite_commands, [:actor_user_id])
    create index(:sprite_commands, [:managed_sprite_id, :inserted_at])

    create table(:sprite_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :managed_sprite_id,
          references(:managed_sprites, on_delete: :delete_all, type: :binary_id)

      add :actor_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :event_type, :string, null: false
      add :severity, :string, null: false, default: "info"
      add :payload, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:sprite_events, [:managed_sprite_id])
    create index(:sprite_events, [:event_type])
    create index(:sprite_events, [:occurred_at])
  end
end
