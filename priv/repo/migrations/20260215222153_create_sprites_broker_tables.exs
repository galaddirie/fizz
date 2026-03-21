defmodule Fizz.Repo.Migrations.CreateSpritesBrokerTables do
  use Ecto.Migration

  def change do
    create table(:sprites, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :created_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :name, :string, null: false
      add :remote_name, :string, null: false
      add :remote_id, :string
      add :status, :string, null: false, default: "provisioning"
      add :url, :string
      add :url_auth_mode, :string
      add :config, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :last_seen_at, :utc_datetime_usec
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sprites, [:remote_name])
    create unique_index(:sprites, [:workspace_id, :name])
    create index(:sprites, [:workspace_id, :status])

    create table(:workspace_sprite_limits, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :max_sprites, :integer, null: false, default: 20
      add :max_concurrent_jobs, :integer, null: false, default: 5
      add :max_jobs_per_minute, :integer, null: false, default: 30
      add :max_console_sessions, :integer, null: false, default: 2
      add :max_services_per_sprite, :integer, null: false, default: 10
      add :max_checkpoints_per_sprite, :integer, null: false, default: 50
      add :daily_exec_seconds_limit, :bigint, null: false, default: 36_000
      add :daily_log_bytes_limit, :bigint, null: false, default: 2_147_483_648

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspace_sprite_limits, [:workspace_id])

    create table(:workspace_usage_daily, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :usage_date, :date, null: false
      add :jobs_total, :integer, null: false, default: 0
      add :jobs_succeeded, :integer, null: false, default: 0
      add :jobs_failed, :integer, null: false, default: 0
      add :jobs_canceled, :integer, null: false, default: 0
      add :exec_seconds, :bigint, null: false, default: 0
      add :log_bytes, :bigint, null: false, default: 0
      add :console_seconds, :bigint, null: false, default: 0
      add :sprites_created, :integer, null: false, default: 0
      add :sprites_deleted, :integer, null: false, default: 0
      add :quota_rejections, :integer, null: false, default: 0
      add :rate_limited, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspace_usage_daily, [:workspace_id, :usage_date])

    create table(:sprite_exec_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :sprite_id, references(:sprites, on_delete: :delete_all, type: :binary_id), null: false

      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :requested_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :state, :string, null: false, default: "queued"
      add :command, :string, null: false
      add :args, {:array, :string}, null: false, default: []
      add :env, :map, null: false, default: %{}
      add :dir, :string
      add :tty, :boolean, null: false, default: false
      add :timeout_ms, :integer
      add :exit_code, :integer
      add :remote_session_id, :string
      add :bytes_stdout, :bigint, null: false, default: 0
      add :bytes_stderr, :bigint, null: false, default: 0
      add :bytes_total, :bigint, null: false, default: 0
      add :error_code, :string
      add :error_message, :string
      add :heartbeat_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :cancel_requested_at, :utc_datetime_usec
      add :oban_job_id, :bigint

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sprite_exec_jobs, [:workspace_id, :inserted_at])
    create index(:sprite_exec_jobs, [:state, :heartbeat_at])
    create index(:sprite_exec_jobs, [:sprite_id, :state])
    create index(:sprite_exec_jobs, [:oban_job_id])

    create table(:sprite_exec_log_chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :job_id, references(:sprite_exec_jobs, on_delete: :delete_all, type: :binary_id),
        null: false

      add :seq, :bigint, null: false
      add :stream, :string, null: false
      add :chunk, :binary, null: false
      add :byte_size, :integer, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    create unique_index(:sprite_exec_log_chunks, [:job_id, :seq])
    create index(:sprite_exec_log_chunks, [:inserted_at])

    create table(:sprite_console_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :sprite_id, references(:sprites, on_delete: :delete_all, type: :binary_id), null: false

      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :opened_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :remote_session_id, :string
      add :state, :string, null: false, default: "active"
      add :opened_at, :utc_datetime_usec
      add :closed_at, :utc_datetime_usec
      add :close_reason, :string
      add :rows, :integer, null: false, default: 24
      add :cols, :integer, null: false, default: 80

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sprite_console_sessions, [:workspace_id, :state])
    create index(:sprite_console_sessions, [:sprite_id, :state])

    create table(:sprite_services, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :sprite_id, references(:sprites, on_delete: :delete_all, type: :binary_id), null: false

      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :name, :string, null: false
      add :cmd, :string
      add :args, {:array, :string}, null: false, default: []
      add :needs, {:array, :string}, null: false, default: []
      add :status, :string, null: false, default: "stopped"
      add :published, :boolean, null: false, default: false
      add :metadata, :map, null: false, default: %{}
      add :last_started_at, :utc_datetime_usec
      add :last_stopped_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sprite_services, [:sprite_id, :name])
    create index(:sprite_services, [:workspace_id, :status])

    create table(:sprite_checkpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :sprite_id, references(:sprites, on_delete: :delete_all, type: :binary_id), null: false

      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :remote_checkpoint_id, :string, null: false
      add :comment, :string
      add :created_at_remote, :utc_datetime_usec
      add :created_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sprite_checkpoints, [:sprite_id, :remote_checkpoint_id])
    create index(:sprite_checkpoints, [:workspace_id, :inserted_at])

    create table(:workspace_rate_limit_windows, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :bucket, :string, null: false
      add :window_start, :utc_datetime_usec, null: false
      add :count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :workspace_rate_limit_windows,
             [:workspace_id, :bucket, :window_start],
             name: :workspace_rate_limit_windows_ws_bucket_window_idx
           )

    create index(:workspace_rate_limit_windows, [:workspace_id, :window_start])
  end
end
