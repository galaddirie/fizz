defmodule Fizz.Repo.Migrations.CreateWorkflowAndExecutionTables do
  use Ecto.Migration

  def change do
    create table(:workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :status, :string, null: false, default: "draft"
      add :current_version_tag, :string
      add :published_version_id, :binary_id

      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :user_id, references(:users, on_delete: :nothing, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflows, [:workspace_id])
    create index(:workflows, [:user_id])
    create index(:workflows, [:status])
    create index(:workflows, [:published_version_id])
    create index(:workflows, [:workspace_id, :user_id])

    create table(:workflow_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :version_tag, :string, null: false
      add :source_hash, :string, null: false
      add :steps, {:array, :map}, null: false, default: []
      add :connections, {:array, :map}, null: false, default: []
      add :groups, {:array, :map}, null: false, default: []
      add :changelog, :string
      add :published_at, :utc_datetime_usec
      add :published_by, references(:users, on_delete: :nilify_all, type: :binary_id)

      add :workflow_id, references(:workflows, on_delete: :delete_all, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:workflow_versions, [:workflow_id])
    create index(:workflow_versions, [:published_by])
    create index(:workflow_versions, [:workflow_id, :published_at])
    create unique_index(:workflow_versions, [:workflow_id, :version_tag])

    create table(:workflow_drafts, primary_key: false) do
      add :workflow_id, references(:workflows, on_delete: :delete_all, type: :binary_id),
        primary_key: true,
        null: false

      add :steps, {:array, :map}, null: false, default: []
      add :connections, {:array, :map}, null: false, default: []
      add :groups, {:array, :map}, null: false, default: []
      add :editor_state, :map, null: false, default: %{}

      add :settings, :map,
        null: false,
        default: %{"timeout_ms" => 300_000, "max_retries" => 3}

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      """
      ALTER TABLE workflows
      ADD CONSTRAINT workflows_published_version_id_fkey
      FOREIGN KEY (published_version_id)
      REFERENCES workflow_versions(id)
      ON DELETE SET NULL
      """,
      """
      ALTER TABLE workflows
      DROP CONSTRAINT IF EXISTS workflows_published_version_id_fkey
      """
    )

    create table(:executions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_id, references(:workflows, on_delete: :delete_all, type: :binary_id),
        null: false

      add :status, :string, null: false, default: "pending"
      add :execution_type, :string, null: false, default: "production"
      add :trigger, :map, null: false
      add :metadata, :map
      add :context, :map, null: false, default: %{}
      add :output, :map
      add :error, :map
      add :waiting_for, :map
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :triggered_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:executions, [:workflow_id])
    create index(:executions, [:status])
    create index(:executions, [:execution_type])
    create index(:executions, [:triggered_by_user_id])
    create index(:executions, [:workflow_id, :inserted_at])

    create table(:step_executions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :execution_id, references(:executions, on_delete: :delete_all, type: :binary_id),
        null: false

      add :step_id, :string, null: false
      add :step_type_id, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :input_data, :map
      add :output_data, :map
      add :output_item_count, :integer
      add :item_index, :integer
      add :items_total, :integer
      add :error, :map
      add :metadata, :map, null: false, default: %{}
      add :queued_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :attempt, :integer, null: false, default: 1
      add :retry_of_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create index(:step_executions, [:execution_id])
    create index(:step_executions, [:execution_id, :step_id])
    create index(:step_executions, [:execution_id, :status])
    create index(:step_executions, [:execution_id, :inserted_at])
    create index(:step_executions, [:execution_id, :step_id, :attempt, :item_index, :inserted_at])

    create table(:edit_operations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :operation_id, :string, null: false
      add :seq, :integer, null: false
      add :type, :string, null: false
      add :payload, :map, null: false
      add :user_id, :binary_id
      add :client_seq, :integer

      add :workflow_id, references(:workflows, on_delete: :delete_all, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:edit_operations, [:operation_id])
    create unique_index(:edit_operations, [:workflow_id, :seq])
    create index(:edit_operations, [:workflow_id])
  end
end
