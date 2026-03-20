defmodule Fizz.Repo.Migrations.CreateTriggerTables do
  use Ecto.Migration

  def change do
    create table(:trigger_registrations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_definition_id,
          references(:workflow_definitions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :definition_version_id,
          references(:workflow_definition_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :step_id, :string, null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workos_organization_id, :string, null: false

      add :run_id, references(:workflow_runs, type: :binary_id, on_delete: :delete_all)

      add :kind, :string, null: false
      add :status, :string, null: false, default: "active"
      add :registration_params, :map, null: false, default: fragment("'{}'::jsonb")
      add :config_digest, :string, null: false

      add :webhook_path, :string
      add :webhook_secret, :string

      add :cron_expression, :string
      add :next_fire_at, :utc_datetime_usec

      add :cursor, :map
      add :poll_interval_ms, :integer
      add :last_polled_at, :utc_datetime_usec
      add :batch_size, :integer, null: false, default: 100

      add :error_message, :string
      add :consecutive_errors, :integer, null: false, default: 0
      add :last_error_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :trigger_registrations,
             :trigger_registrations_kind_check,
             check: "kind IN ('manual', 'webhook', 'schedule', 'polling', 'subscription', 'chat')"
           )

    create constraint(
             :trigger_registrations,
             :trigger_registrations_status_check,
             check: "status IN ('active', 'paused', 'errored', 'inactive', 'firing')"
           )

    create unique_index(
             :trigger_registrations,
             [:definition_version_id, :step_id],
             where: "run_id IS NULL",
             name: :trigger_registrations_definition_level_step_index
           )

    create unique_index(
             :trigger_registrations,
             [:run_id, :step_id],
             where: "run_id IS NOT NULL",
             name: :trigger_registrations_run_level_step_index
           )

    create unique_index(
             :trigger_registrations,
             [:webhook_path],
             where: "webhook_path IS NOT NULL AND status = 'active'",
             name: :trigger_registrations_active_webhook_path_index
           )

    create index(
             :trigger_registrations,
             [:next_fire_at],
             where: "kind = 'schedule' AND status = 'active' AND next_fire_at IS NOT NULL",
             name: :trigger_registrations_schedule_due_index
           )

    create index(
             :trigger_registrations,
             [:project_id, :status],
             name: :trigger_registrations_project_status_index
           )

    create table(:trigger_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :trigger_registration_id,
          references(:trigger_registrations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workos_organization_id, :string, null: false
      add :event_id, :string, null: false
      add :event_data, :map
      add :status, :string, null: false, default: "pending"
      add :run_id, :binary_id
      add :processed_at, :utc_datetime_usec

      timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
    end

    create constraint(
             :trigger_events,
             :trigger_events_status_check,
             check: "status IN ('pending', 'processing', 'fired', 'skipped', 'failed')"
           )

    create unique_index(
             :trigger_events,
             [:trigger_registration_id, :event_id],
             name: :trigger_events_registration_event_id_index
           )

    create index(
             :trigger_events,
             [:created_at],
             where: "status IN ('fired', 'skipped', 'failed')",
             name: :trigger_events_cleanup_index
           )
  end
end
