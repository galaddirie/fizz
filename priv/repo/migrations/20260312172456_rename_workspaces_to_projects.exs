defmodule Fizz.Repo.Migrations.RenameWorkspacesToProjects do
  use Ecto.Migration

  def change do
    rename table(:workspaces), to: table(:projects)
    rename table(:workspace_memberships), to: table(:project_memberships)

    rename table(:project_memberships), :workspace_id, to: :project_id
    rename table(:sprites), :workspace_id, to: :project_id
    rename table(:sprite_checkpoints), :workspace_id, to: :project_id
    rename table(:sprite_console_sessions), :workspace_id, to: :project_id
    rename table(:sprite_exec_jobs), :workspace_id, to: :project_id
    rename table(:sprite_services), :workspace_id, to: :project_id
    rename table(:workflows), :workspace_id, to: :project_id

    execute(
      "ALTER INDEX workspaces_workos_organization_id_index RENAME TO projects_workos_organization_id_index",
      "ALTER INDEX projects_workos_organization_id_index RENAME TO workspaces_workos_organization_id_index"
    )

    execute(
      "ALTER INDEX workspaces_workos_organization_id_slug_index RENAME TO projects_workos_organization_id_slug_index",
      "ALTER INDEX projects_workos_organization_id_slug_index RENAME TO workspaces_workos_organization_id_slug_index"
    )

    execute(
      "ALTER INDEX workspace_memberships_user_id_index RENAME TO project_memberships_user_id_index",
      "ALTER INDEX project_memberships_user_id_index RENAME TO workspace_memberships_user_id_index"
    )

    execute(
      "ALTER INDEX workspace_memberships_workspace_id_user_id_index RENAME TO project_memberships_project_id_user_id_index",
      "ALTER INDEX project_memberships_project_id_user_id_index RENAME TO workspace_memberships_workspace_id_user_id_index"
    )

    execute(
      "ALTER INDEX sprites_workspace_id_name_index RENAME TO sprites_project_id_name_index",
      "ALTER INDEX sprites_project_id_name_index RENAME TO sprites_workspace_id_name_index"
    )

    execute(
      "ALTER INDEX sprites_workspace_id_status_index RENAME TO sprites_project_id_status_index",
      "ALTER INDEX sprites_project_id_status_index RENAME TO sprites_workspace_id_status_index"
    )

    execute(
      "ALTER INDEX sprite_checkpoints_workspace_id_inserted_at_index RENAME TO sprite_checkpoints_project_id_inserted_at_index",
      "ALTER INDEX sprite_checkpoints_project_id_inserted_at_index RENAME TO sprite_checkpoints_workspace_id_inserted_at_index"
    )

    execute(
      "ALTER INDEX sprite_console_sessions_workspace_id_state_index RENAME TO sprite_console_sessions_project_id_state_index",
      "ALTER INDEX sprite_console_sessions_project_id_state_index RENAME TO sprite_console_sessions_workspace_id_state_index"
    )

    execute(
      "ALTER INDEX sprite_exec_jobs_workspace_id_inserted_at_index RENAME TO sprite_exec_jobs_project_id_inserted_at_index",
      "ALTER INDEX sprite_exec_jobs_project_id_inserted_at_index RENAME TO sprite_exec_jobs_workspace_id_inserted_at_index"
    )

    execute(
      "ALTER INDEX sprite_services_workspace_id_status_index RENAME TO sprite_services_project_id_status_index",
      "ALTER INDEX sprite_services_project_id_status_index RENAME TO sprite_services_workspace_id_status_index"
    )

    execute(
      "ALTER INDEX workflows_workspace_id_index RENAME TO workflows_project_id_index",
      "ALTER INDEX workflows_project_id_index RENAME TO workflows_workspace_id_index"
    )

    execute(
      "ALTER INDEX workflows_workspace_id_user_id_index RENAME TO workflows_project_id_user_id_index",
      "ALTER INDEX workflows_project_id_user_id_index RENAME TO workflows_workspace_id_user_id_index"
    )

    execute(
      "ALTER TABLE projects RENAME CONSTRAINT workspaces_pkey TO projects_pkey",
      "ALTER TABLE projects RENAME CONSTRAINT projects_pkey TO workspaces_pkey"
    )

    execute(
      "ALTER TABLE project_memberships RENAME CONSTRAINT workspace_memberships_pkey TO project_memberships_pkey",
      "ALTER TABLE project_memberships RENAME CONSTRAINT project_memberships_pkey TO workspace_memberships_pkey"
    )

    execute(
      "ALTER TABLE project_memberships RENAME CONSTRAINT workspace_memberships_user_id_fkey TO project_memberships_user_id_fkey",
      "ALTER TABLE project_memberships RENAME CONSTRAINT project_memberships_user_id_fkey TO workspace_memberships_user_id_fkey"
    )

    execute(
      "ALTER TABLE project_memberships RENAME CONSTRAINT workspace_memberships_workspace_id_fkey TO project_memberships_project_id_fkey",
      "ALTER TABLE project_memberships RENAME CONSTRAINT project_memberships_project_id_fkey TO workspace_memberships_workspace_id_fkey"
    )

    execute(
      "ALTER TABLE sprites RENAME CONSTRAINT sprites_workspace_id_fkey TO sprites_project_id_fkey",
      "ALTER TABLE sprites RENAME CONSTRAINT sprites_project_id_fkey TO sprites_workspace_id_fkey"
    )

    execute(
      "ALTER TABLE sprite_checkpoints RENAME CONSTRAINT sprite_checkpoints_workspace_id_fkey TO sprite_checkpoints_project_id_fkey",
      "ALTER TABLE sprite_checkpoints RENAME CONSTRAINT sprite_checkpoints_project_id_fkey TO sprite_checkpoints_workspace_id_fkey"
    )

    execute(
      "ALTER TABLE sprite_console_sessions RENAME CONSTRAINT sprite_console_sessions_workspace_id_fkey TO sprite_console_sessions_project_id_fkey",
      "ALTER TABLE sprite_console_sessions RENAME CONSTRAINT sprite_console_sessions_project_id_fkey TO sprite_console_sessions_workspace_id_fkey"
    )

    execute(
      "ALTER TABLE sprite_exec_jobs RENAME CONSTRAINT sprite_exec_jobs_workspace_id_fkey TO sprite_exec_jobs_project_id_fkey",
      "ALTER TABLE sprite_exec_jobs RENAME CONSTRAINT sprite_exec_jobs_project_id_fkey TO sprite_exec_jobs_workspace_id_fkey"
    )

    execute(
      "ALTER TABLE sprite_services RENAME CONSTRAINT sprite_services_workspace_id_fkey TO sprite_services_project_id_fkey",
      "ALTER TABLE sprite_services RENAME CONSTRAINT sprite_services_project_id_fkey TO sprite_services_workspace_id_fkey"
    )

    execute(
      "ALTER TABLE workflows RENAME CONSTRAINT workflows_workspace_id_fkey TO workflows_project_id_fkey",
      "ALTER TABLE workflows RENAME CONSTRAINT workflows_project_id_fkey TO workflows_workspace_id_fkey"
    )
  end
end
