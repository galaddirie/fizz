defmodule Fizz.Repo.Migrations.CreateExecutionPrimitives do
  use Ecto.Migration

  def change do
    create table(:executions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_id, references(:workflows, on_delete: :delete_all, type: :binary_id),
        null: false

      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
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
    create index(:executions, [:workspace_id])
    create index(:executions, [:status])
    create index(:executions, [:execution_type])
    create index(:executions, [:triggered_by_user_id])
    create index(:executions, [:workspace_id, :workflow_id])
    create index(:executions, [:workspace_id, :inserted_at])

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
  end
end
