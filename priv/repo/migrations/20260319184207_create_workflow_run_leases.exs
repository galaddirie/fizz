defmodule Fizz.Repo.Migrations.CreateWorkflowRunLeases do
  use Ecto.Migration

  def change do
    create table(:workflow_run_leases, primary_key: false) do
      add :run_id, :binary_id, primary_key: true
      add :owner_node, :string
      add :fence_token, :bigint, null: false, default: 0
      add :checkpoint_seq, :bigint, null: false, default: 0
      add :lease_expiry, :utc_datetime_usec, null: false
    end

    create index(:workflow_run_leases, [:lease_expiry])
  end
end
