defmodule Fizz.Repo.Migrations.AddUserIdToWorkflowRuns do
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      add :user_id, :string, null: false
    end

    create index(:workflow_runs, [:user_id])
    create index(:workflow_runs, [:user_id, :workflow_definition_id])
  end
end
