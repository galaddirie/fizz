defmodule Fizz.Repo.Migrations.AddUserIdToWorkflowRuns do
  use Ecto.Migration

  def up do
    alter table(:workflow_runs) do
      add :user_id, :string
    end

    execute("""
    UPDATE workflow_runs AS runs
    SET user_id = COALESCE(versions.published_by_user_id, definitions.created_by_user_id)
    FROM workflow_definition_versions AS versions
    JOIN workflow_definitions AS definitions
      ON definitions.id = versions.workflow_definition_id
    WHERE runs.workflow_definition_version_id = versions.id
      AND runs.workflow_definition_id = definitions.id
      AND runs.user_id IS NULL
    """)

    execute("""
    DELETE FROM workflow_run_leases
    WHERE run_id IN (
      SELECT id FROM workflow_runs WHERE user_id IS NULL
    )
    """)

    execute("""
    DELETE FROM trigger_events
    WHERE run_id IN (
      SELECT id FROM workflow_runs WHERE user_id IS NULL
    )
    """)

    execute("DELETE FROM workflow_runs WHERE user_id IS NULL")

    alter table(:workflow_runs) do
      modify :user_id, :string, null: false
    end

    create index(:workflow_runs, [:user_id])
    create index(:workflow_runs, [:user_id, :workflow_definition_id])
  end

  def down do
    drop index(:workflow_runs, [:user_id, :workflow_definition_id])
    drop index(:workflow_runs, [:user_id])

    alter table(:workflow_runs) do
      remove :user_id
    end
  end
end
