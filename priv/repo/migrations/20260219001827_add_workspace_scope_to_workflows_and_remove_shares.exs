defmodule Fizz.Repo.Migrations.AddWorkspaceScopeToWorkflowsAndRemoveShares do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      workflows_fully_scoped boolean;
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'workflows'
      ) THEN
        EXECUTE 'ALTER TABLE workflows ADD COLUMN IF NOT EXISTS workspace_id uuid';

        IF EXISTS (
          SELECT 1
          FROM information_schema.tables
          WHERE table_schema = 'public' AND table_name = 'workspace_memberships'
        ) THEN
          EXECUTE '
            UPDATE workflows AS w
            SET workspace_id = seeded.workspace_id
            FROM (
              SELECT DISTINCT ON (wm.user_id)
                     wm.user_id,
                     wm.workspace_id
              FROM workspace_memberships AS wm
              ORDER BY wm.user_id, wm.inserted_at
            ) AS seeded
            WHERE w.workspace_id IS NULL
              AND w.user_id = seeded.user_id
          ';
        END IF;

        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint
          WHERE conname = 'workflows_workspace_id_fkey'
        ) THEN
          EXECUTE '
            ALTER TABLE workflows
            ADD CONSTRAINT workflows_workspace_id_fkey
            FOREIGN KEY (workspace_id)
            REFERENCES workspaces(id)
            ON DELETE RESTRICT
          ';
        END IF;

        IF NOT EXISTS (
          SELECT 1
          FROM pg_indexes
          WHERE schemaname = 'public' AND indexname = 'workflows_workspace_id_index'
        ) THEN
          EXECUTE 'CREATE INDEX workflows_workspace_id_index ON workflows (workspace_id)';
        END IF;

        EXECUTE 'SELECT NOT EXISTS (SELECT 1 FROM workflows WHERE workspace_id IS NULL)'
          INTO workflows_fully_scoped;

        IF workflows_fully_scoped THEN
          EXECUTE 'ALTER TABLE workflows ALTER COLUMN workspace_id SET NOT NULL';
        END IF;

        EXECUTE 'ALTER TABLE workflows DROP COLUMN IF EXISTS public';
      END IF;
    END
    $$;
    """)

    execute("DROP TABLE IF EXISTS workflow_shares")
  end

  def down do
    raise "This migration is irreversible"
  end
end
