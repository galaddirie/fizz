defmodule Fizz.Repo.Migrations.CreateWorkflowRuns do
  use Ecto.Migration

  def change do
    create table(:workflow_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_definition_id,
          references(:workflow_definitions, type: :binary_id, on_delete: :restrict),
          null: false

      add :workflow_definition_version_id,
          references(:workflow_definition_versions, type: :binary_id, on_delete: :restrict),
          null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workos_organization_id, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :input, :map, null: false, default: fragment("'{}'::jsonb")
      add :output, :map
      add :error, :map
      add :storage_uri, :string
      add :last_active_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      add :continued_from_run_id,
          references(:workflow_runs, type: :binary_id, on_delete: :nilify_all)

      add :compiled_hash, :string

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :workflow_runs,
             :workflow_runs_status_check,
             check:
               "status IN ('pending', 'running', 'sleeping', 'passivated', 'completed', 'failed', 'cancelled', 'continued')"
           )

    create index(:workflow_runs, [:project_id, :status])
    create index(:workflow_runs, [:workflow_definition_id])
    create index(:workflow_runs, [:status, :last_active_at])
    create index(:workflow_runs, [:continued_from_run_id])
  end
end
