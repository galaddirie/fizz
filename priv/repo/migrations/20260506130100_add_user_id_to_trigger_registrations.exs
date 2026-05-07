defmodule Fizz.Repo.Migrations.AddUserIdToTriggerRegistrations do
  use Ecto.Migration

  def change do
    alter table(:trigger_registrations) do
      add :user_id, :string, null: false
    end

    drop_if_exists unique_index(:trigger_registrations, [:definition_version_id, :step_id],
                     name: :trigger_registrations_definition_level_step_index
                   )

    create unique_index(:trigger_registrations, [:definition_version_id, :step_id, :user_id],
             name: :trigger_registrations_definition_level_step_user_index
           )

    create index(:trigger_registrations, [:user_id])
  end
end
