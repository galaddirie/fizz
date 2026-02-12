defmodule Fizz.Repo.Migrations.RemoveSpriteStateMirrors do
  use Ecto.Migration

  def up do
    drop_if_exists index(:managed_sprites, [:workspace_id, :status])

    alter table(:managed_sprites) do
      remove :status
      remove :url
      remove :last_reconciled_at
    end

    drop table(:sprite_sessions)
  end

  def down do
    alter table(:managed_sprites) do
      add :status, :string, null: false, default: "pending"
      add :url, :string
      add :last_reconciled_at, :utc_datetime_usec
    end

    create index(:managed_sprites, [:workspace_id, :status])

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
  end
end
