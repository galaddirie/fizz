defmodule Fizz.Repo.Migrations.CreateDurableTimersAndSignals do
  use Ecto.Migration

  def change do
    create table(:durable_timers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:workflow_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :step_id, :string, null: false
      add :timer_name, :string, null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workos_organization_id, :string, null: false
      add :fire_at, :utc_datetime_usec, null: false
      add :status, :string, null: false, default: "pending"
      add :payload, :map
      add :claimed_at, :utc_datetime_usec
      add :claimed_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :durable_timers,
             :durable_timers_status_check,
             check: "status IN ('pending', 'firing', 'fired', 'cancelled')"
           )

    create index(:durable_timers, [:fire_at], where: "status = 'pending'")
    create index(:durable_timers, [:run_id], where: "status = 'pending'")
    create index(:durable_timers, [:claimed_at], where: "status = 'firing'")

    create table(:signal_inbox, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:workflow_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :signal_id, :string, null: false
      add :signal_name, :string, null: false
      add :payload, :map, null: false, default: fragment("'{}'::jsonb")
      add :status, :string, null: false, default: "pending"

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workos_organization_id, :string, null: false
      add :delivered_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :signal_inbox,
             :signal_inbox_status_check,
             check: "status IN ('pending', 'delivered', 'skipped')"
           )

    create unique_index(:signal_inbox, [:run_id, :signal_id])
    create index(:signal_inbox, [:run_id], where: "status = 'pending'")
  end
end
