defmodule Fizz.Repo.Migrations.AddWorkflowRunLeaseForeignKey do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM workflow_run_leases AS leases
    WHERE NOT EXISTS (
      SELECT 1
      FROM workflow_runs AS runs
      WHERE runs.id = leases.run_id
    )
    """)

    execute("""
    ALTER TABLE workflow_run_leases
    ADD CONSTRAINT workflow_run_leases_run_id_fkey
    FOREIGN KEY (run_id)
    REFERENCES workflow_runs(id)
    ON DELETE CASCADE
    """)
  end

  def down do
    execute("""
    ALTER TABLE workflow_run_leases
    DROP CONSTRAINT IF EXISTS workflow_run_leases_run_id_fkey
    """)
  end
end
