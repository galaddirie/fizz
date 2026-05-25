defmodule Fizz.Repo.Migrations.AddSignalClaimsAndWorkflowRuntimeIndexes do
  use Ecto.Migration

  def up do
    alter table(:signal_inbox) do
      add :claimed_at, :utc_datetime_usec
      add :claimed_by, :string
    end

    drop constraint(:signal_inbox, :signal_inbox_status_check)

    create constraint(
             :signal_inbox,
             :signal_inbox_status_check,
             check: "status IN ('pending', 'delivering', 'delivered', 'skipped')"
           )

    create index(:signal_inbox, [:inserted_at],
             where: "status = 'pending'",
             name: :signal_inbox_pending_inserted_at_index
           )

    create index(:signal_inbox, [:claimed_at],
             where: "status = 'delivering'",
             name: :signal_inbox_delivering_claimed_at_index
           )

    create index(:workflow_runs, [:last_active_at],
             where: "status IN ('running', 'sleeping')",
             name: :workflow_runs_passivation_candidates_index
           )
  end

  def down do
    drop index(:workflow_runs, [:last_active_at],
           name: :workflow_runs_passivation_candidates_index
         )

    drop index(:signal_inbox, [:claimed_at], name: :signal_inbox_delivering_claimed_at_index)

    drop index(:signal_inbox, [:inserted_at], name: :signal_inbox_pending_inserted_at_index)

    drop constraint(:signal_inbox, :signal_inbox_status_check)

    create constraint(
             :signal_inbox,
             :signal_inbox_status_check,
             check: "status IN ('pending', 'delivered', 'skipped')"
           )

    alter table(:signal_inbox) do
      remove :claimed_at
      remove :claimed_by
    end
  end
end
