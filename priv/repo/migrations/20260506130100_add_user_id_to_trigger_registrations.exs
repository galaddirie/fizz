defmodule Fizz.Repo.Migrations.AddUserIdToTriggerRegistrations do
  use Ecto.Migration

  def up do
    alter table(:trigger_registrations) do
      add :user_id, :string
    end

    execute("""
    UPDATE trigger_registrations AS registrations
    SET user_id = resolved.user_id
    FROM (
      SELECT
        registrations.id,
        COALESCE(
          runs.user_id,
          versions.published_by_user_id,
          definitions.created_by_user_id
        ) AS user_id
      FROM trigger_registrations AS registrations
      JOIN workflow_definition_versions AS versions
        ON versions.id = registrations.definition_version_id
      JOIN workflow_definitions AS definitions
        ON definitions.id = versions.workflow_definition_id
      LEFT JOIN workflow_runs AS runs
        ON runs.id = registrations.run_id
      WHERE registrations.user_id IS NULL
        AND registrations.workflow_definition_id = definitions.id
    ) AS resolved
    WHERE registrations.id = resolved.id
      AND registrations.user_id IS NULL
    """)

    execute("""
    DELETE FROM trigger_events
    WHERE trigger_registration_id IN (
      SELECT id FROM trigger_registrations WHERE user_id IS NULL
    )
    """)

    execute("DELETE FROM trigger_registrations WHERE user_id IS NULL")

    alter table(:trigger_registrations) do
      modify :user_id, :string, null: false
    end

    drop_if_exists unique_index(:trigger_registrations, [:definition_version_id, :step_id],
                     name: :trigger_registrations_definition_level_step_index
                   )

    create unique_index(:trigger_registrations, [:definition_version_id, :step_id, :user_id],
             name: :trigger_registrations_definition_level_step_user_index
           )

    create index(:trigger_registrations, [:user_id])
  end

  def down do
    drop index(:trigger_registrations, [:user_id])

    drop unique_index(:trigger_registrations, [:definition_version_id, :step_id, :user_id],
           name: :trigger_registrations_definition_level_step_user_index
         )

    create unique_index(:trigger_registrations, [:definition_version_id, :step_id],
             where: "run_id IS NULL",
             name: :trigger_registrations_definition_level_step_index
           )

    alter table(:trigger_registrations) do
      remove :user_id
    end
  end
end
