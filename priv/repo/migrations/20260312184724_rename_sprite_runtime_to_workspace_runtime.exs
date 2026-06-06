defmodule Fizz.Repo.Migrations.RenameSpriteRuntimeToWorkspaceRuntime do
  use Ecto.Migration

  def change do
    rename table(:sprites), to: table(:workspaces)
    rename table(:sprite_checkpoints), to: table(:workspace_checkpoints)
    rename table(:sprite_console_sessions), to: table(:workspace_console_sessions)
    rename table(:sprite_exec_jobs), to: table(:workspace_exec_jobs)
    rename table(:sprite_exec_log_chunks), to: table(:workspace_exec_log_chunks)
    rename table(:sprite_services), to: table(:workspace_services)

    rename table(:workspace_checkpoints), :sprite_id, to: :workspace_id
    rename table(:workspace_console_sessions), :sprite_id, to: :workspace_id
    rename table(:workspace_exec_jobs), :sprite_id, to: :workspace_id
    rename table(:workspace_services), :sprite_id, to: :workspace_id

    execute(
      "ALTER INDEX sprites_remote_name_index RENAME TO workspaces_remote_name_index",
      "ALTER INDEX workspaces_remote_name_index RENAME TO sprites_remote_name_index"
    )

    execute(
      "ALTER INDEX sprites_project_id_name_index RENAME TO workspaces_project_id_name_index",
      "ALTER INDEX workspaces_project_id_name_index RENAME TO sprites_project_id_name_index"
    )

    execute(
      "ALTER INDEX sprites_project_id_status_index RENAME TO workspaces_project_id_status_index",
      "ALTER INDEX workspaces_project_id_status_index RENAME TO sprites_project_id_status_index"
    )

    execute(
      "ALTER INDEX sprite_checkpoints_project_id_inserted_at_index RENAME TO workspace_checkpoints_project_id_inserted_at_index",
      "ALTER INDEX workspace_checkpoints_project_id_inserted_at_index RENAME TO sprite_checkpoints_project_id_inserted_at_index"
    )

    execute(
      "ALTER INDEX sprite_checkpoints_sprite_id_remote_checkpoint_id_index RENAME TO workspace_checkpoints_workspace_id_remote_checkpoint_id_index",
      "ALTER INDEX workspace_checkpoints_workspace_id_remote_checkpoint_id_index RENAME TO sprite_checkpoints_sprite_id_remote_checkpoint_id_index"
    )

    execute(
      "ALTER INDEX sprite_console_sessions_project_id_state_index RENAME TO workspace_console_sessions_project_id_state_index",
      "ALTER INDEX workspace_console_sessions_project_id_state_index RENAME TO sprite_console_sessions_project_id_state_index"
    )

    execute(
      "ALTER INDEX sprite_exec_jobs_project_id_inserted_at_index RENAME TO workspace_exec_jobs_project_id_inserted_at_index",
      "ALTER INDEX workspace_exec_jobs_project_id_inserted_at_index RENAME TO sprite_exec_jobs_project_id_inserted_at_index"
    )

    execute(
      "ALTER INDEX sprite_exec_log_chunks_job_id_seq_index RENAME TO workspace_exec_log_chunks_job_id_seq_index",
      "ALTER INDEX workspace_exec_log_chunks_job_id_seq_index RENAME TO sprite_exec_log_chunks_job_id_seq_index"
    )

    execute(
      "ALTER INDEX sprite_services_project_id_status_index RENAME TO workspace_services_project_id_status_index",
      "ALTER INDEX workspace_services_project_id_status_index RENAME TO sprite_services_project_id_status_index"
    )

    execute(
      "ALTER INDEX sprite_services_sprite_id_name_index RENAME TO workspace_services_workspace_id_name_index",
      "ALTER INDEX workspace_services_workspace_id_name_index RENAME TO sprite_services_sprite_id_name_index"
    )

    execute(
      "ALTER TABLE workspaces RENAME CONSTRAINT sprites_pkey TO workspaces_pkey",
      "ALTER TABLE workspaces RENAME CONSTRAINT workspaces_pkey TO sprites_pkey"
    )

    execute(
      "ALTER TABLE workspace_checkpoints RENAME CONSTRAINT sprite_checkpoints_pkey TO workspace_checkpoints_pkey",
      "ALTER TABLE workspace_checkpoints RENAME CONSTRAINT workspace_checkpoints_pkey TO sprite_checkpoints_pkey"
    )

    execute(
      "ALTER TABLE workspace_console_sessions RENAME CONSTRAINT sprite_console_sessions_pkey TO workspace_console_sessions_pkey",
      "ALTER TABLE workspace_console_sessions RENAME CONSTRAINT workspace_console_sessions_pkey TO sprite_console_sessions_pkey"
    )

    execute(
      "ALTER TABLE workspace_exec_jobs RENAME CONSTRAINT sprite_exec_jobs_pkey TO workspace_exec_jobs_pkey",
      "ALTER TABLE workspace_exec_jobs RENAME CONSTRAINT workspace_exec_jobs_pkey TO sprite_exec_jobs_pkey"
    )

    execute(
      "ALTER TABLE workspace_exec_log_chunks RENAME CONSTRAINT sprite_exec_log_chunks_pkey TO workspace_exec_log_chunks_pkey",
      "ALTER TABLE workspace_exec_log_chunks RENAME CONSTRAINT workspace_exec_log_chunks_pkey TO sprite_exec_log_chunks_pkey"
    )

    execute(
      "ALTER TABLE workspace_services RENAME CONSTRAINT sprite_services_pkey TO workspace_services_pkey",
      "ALTER TABLE workspace_services RENAME CONSTRAINT workspace_services_pkey TO sprite_services_pkey"
    )

    execute(
      "ALTER TABLE workspaces RENAME CONSTRAINT sprites_project_id_fkey TO workspaces_project_id_fkey",
      "ALTER TABLE workspaces RENAME CONSTRAINT workspaces_project_id_fkey TO sprites_project_id_fkey"
    )

    execute(
      "ALTER TABLE workspaces RENAME CONSTRAINT sprites_created_by_user_id_fkey TO workspaces_created_by_user_id_fkey",
      "ALTER TABLE workspaces RENAME CONSTRAINT workspaces_created_by_user_id_fkey TO sprites_created_by_user_id_fkey"
    )

    execute(
      "ALTER TABLE workspace_checkpoints RENAME CONSTRAINT sprite_checkpoints_project_id_fkey TO workspace_checkpoints_project_id_fkey",
      "ALTER TABLE workspace_checkpoints RENAME CONSTRAINT workspace_checkpoints_project_id_fkey TO sprite_checkpoints_project_id_fkey"
    )

    execute(
      "ALTER TABLE workspace_checkpoints RENAME CONSTRAINT sprite_checkpoints_created_by_user_id_fkey TO workspace_checkpoints_created_by_user_id_fkey",
      "ALTER TABLE workspace_checkpoints RENAME CONSTRAINT workspace_checkpoints_created_by_user_id_fkey TO sprite_checkpoints_created_by_user_id_fkey"
    )

    execute(
      "ALTER TABLE workspace_checkpoints RENAME CONSTRAINT sprite_checkpoints_sprite_id_fkey TO workspace_checkpoints_workspace_id_fkey",
      "ALTER TABLE workspace_checkpoints RENAME CONSTRAINT workspace_checkpoints_workspace_id_fkey TO sprite_checkpoints_sprite_id_fkey"
    )

    execute(
      "ALTER TABLE workspace_console_sessions RENAME CONSTRAINT sprite_console_sessions_project_id_fkey TO workspace_console_sessions_project_id_fkey",
      "ALTER TABLE workspace_console_sessions RENAME CONSTRAINT workspace_console_sessions_project_id_fkey TO sprite_console_sessions_project_id_fkey"
    )

    execute(
      "ALTER TABLE workspace_console_sessions RENAME CONSTRAINT sprite_console_sessions_opened_by_user_id_fkey TO workspace_console_sessions_opened_by_user_id_fkey",
      "ALTER TABLE workspace_console_sessions RENAME CONSTRAINT workspace_console_sessions_opened_by_user_id_fkey TO sprite_console_sessions_opened_by_user_id_fkey"
    )

    execute(
      "ALTER TABLE workspace_console_sessions RENAME CONSTRAINT sprite_console_sessions_sprite_id_fkey TO workspace_console_sessions_workspace_id_fkey",
      "ALTER TABLE workspace_console_sessions RENAME CONSTRAINT workspace_console_sessions_workspace_id_fkey TO sprite_console_sessions_sprite_id_fkey"
    )

    execute(
      "ALTER TABLE workspace_exec_jobs RENAME CONSTRAINT sprite_exec_jobs_project_id_fkey TO workspace_exec_jobs_project_id_fkey",
      "ALTER TABLE workspace_exec_jobs RENAME CONSTRAINT workspace_exec_jobs_project_id_fkey TO sprite_exec_jobs_project_id_fkey"
    )

    execute(
      "ALTER TABLE workspace_exec_jobs RENAME CONSTRAINT sprite_exec_jobs_requested_by_user_id_fkey TO workspace_exec_jobs_requested_by_user_id_fkey",
      "ALTER TABLE workspace_exec_jobs RENAME CONSTRAINT workspace_exec_jobs_requested_by_user_id_fkey TO sprite_exec_jobs_requested_by_user_id_fkey"
    )

    execute(
      "ALTER TABLE workspace_exec_jobs RENAME CONSTRAINT sprite_exec_jobs_sprite_id_fkey TO workspace_exec_jobs_workspace_id_fkey",
      "ALTER TABLE workspace_exec_jobs RENAME CONSTRAINT workspace_exec_jobs_workspace_id_fkey TO sprite_exec_jobs_sprite_id_fkey"
    )

    execute(
      "ALTER TABLE workspace_exec_log_chunks RENAME CONSTRAINT sprite_exec_log_chunks_job_id_fkey TO workspace_exec_log_chunks_job_id_fkey",
      "ALTER TABLE workspace_exec_log_chunks RENAME CONSTRAINT workspace_exec_log_chunks_job_id_fkey TO sprite_exec_log_chunks_job_id_fkey"
    )

    execute(
      "ALTER TABLE workspace_services RENAME CONSTRAINT sprite_services_project_id_fkey TO workspace_services_project_id_fkey",
      "ALTER TABLE workspace_services RENAME CONSTRAINT workspace_services_project_id_fkey TO sprite_services_project_id_fkey"
    )

    execute(
      "ALTER TABLE workspace_services RENAME CONSTRAINT sprite_services_sprite_id_fkey TO workspace_services_workspace_id_fkey",
      "ALTER TABLE workspace_services RENAME CONSTRAINT workspace_services_workspace_id_fkey TO sprite_services_sprite_id_fkey"
    )
  end
end
