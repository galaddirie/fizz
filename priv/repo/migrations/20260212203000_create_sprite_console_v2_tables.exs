defmodule Fizz.Repo.Migrations.CreateSpriteConsoleV2Tables do
  use Ecto.Migration

  def change do
    create table(:sprite_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :managed_sprite_id,
          references(:managed_sprites, on_delete: :delete_all, type: :binary_id),
          null: false

      add :owner_user_id, references(:users, on_delete: :delete_all, type: :binary_id),
        null: false

      add :pane_id, :string, null: false
      add :provider_session_id, :string
      add :interactive_command, :string, null: false
      add :tty, :boolean, null: false, default: true
      add :state, :string, null: false, default: "starting"
      add :generation, :integer, null: false, default: 1
      add :lease_client_id, :string
      add :lease_acquired_at, :utc_datetime_usec
      add :grace_started_at, :utc_datetime_usec
      add :last_seq, :integer, null: false, default: 0
      add :last_activity_at, :utc_datetime_usec
      add :closed_reason, :string
      add :exit_code, :integer
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sprite_sessions, [:managed_sprite_id])
    create index(:sprite_sessions, [:managed_sprite_id, :owner_user_id])
    create index(:sprite_sessions, [:managed_sprite_id, :owner_user_id, :pane_id])
    create index(:sprite_sessions, [:managed_sprite_id, :owner_user_id, :state])

    create unique_index(:sprite_sessions, [:provider_session_id],
             where: "provider_session_id IS NOT NULL"
           )

    create table(:sprite_console_chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :sprite_session_id,
          references(:sprite_sessions, on_delete: :delete_all, type: :binary_id),
          null: false

      add :seq, :integer, null: false
      add :stream, :string, null: false
      add :data, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:sprite_console_chunks, [:sprite_session_id, :seq],
             name: :sprite_console_chunks_session_seq_idx
           )

    create index(:sprite_console_chunks, [:sprite_session_id, :inserted_at])
  end
end
