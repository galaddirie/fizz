defmodule Fizz.Repo.Migrations.AddTriggeredByToWorkflowRuns do
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      add :triggered_by, :map
    end
  end
end
