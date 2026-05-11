defmodule Fizz.Repo.Migrations.CreateTriggerSources do
  use Ecto.Migration

  def change do
    create table(:trigger_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workos_organization_id, :string, null: false
      add :user_id, :string, null: false
      add :kind, :string, null: false
      add :provider, :string, null: false
      add :source_module, :string, null: false
      add :source_key, :string, null: false
      add :status, :string, null: false, default: "active"
      add :params, :map, null: false, default: fragment("'{}'::jsonb")
      add :cursor, :map
      add :poll_interval_ms, :integer, null: false, default: 60_000
      add :next_poll_at, :utc_datetime_usec
      add :last_polled_at, :utc_datetime_usec
      add :backoff_until, :utc_datetime_usec
      add :lease_owner, :string
      add :lease_expires_at, :utc_datetime_usec
      add :error_message, :string
      add :consecutive_errors, :integer, null: false, default: 0
      add :last_error_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :trigger_sources,
             :trigger_sources_kind_check,
             check: "kind IN ('polling', 'subscription')"
           )

    create constraint(
             :trigger_sources,
             :trigger_sources_status_check,
             check: "status IN ('active', 'paused', 'errored', 'inactive')"
           )

    create unique_index(:trigger_sources, [:source_key], name: :trigger_sources_source_key_index)

    create index(:trigger_sources, [:project_id, :status],
             name: :trigger_sources_project_status_index
           )

    create index(:trigger_sources, [:kind, :status, :next_poll_at],
             name: :trigger_sources_polling_due_index
           )

    create index(:trigger_sources, [:lease_expires_at],
             name: :trigger_sources_lease_expires_at_index
           )

    alter table(:trigger_registrations) do
      add :trigger_source_id,
          references(:trigger_sources, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:trigger_registrations, [:trigger_source_id],
             name: :trigger_registrations_trigger_source_id_index
           )

    create table(:trigger_source_rows, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :trigger_source_id,
          references(:trigger_sources, type: :binary_id, on_delete: :delete_all),
          null: false

      add :row_key, :string, null: false
      add :row_number, :integer, null: false
      add :row_hash, :string, null: false
      add :values, :map, null: false, default: fragment("'{}'::jsonb")
      add :raw_values, {:array, :string}, null: false, default: []
      add :last_seen_at, :utc_datetime_usec, null: false
      add :last_changed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:trigger_source_rows, [:trigger_source_id, :row_key],
             name: :trigger_source_rows_source_row_key_index
           )

    create index(:trigger_source_rows, [:trigger_source_id, :row_number],
             name: :trigger_source_rows_source_row_number_index
           )
  end
end
