defmodule Fizz.Repo.Migrations.ReplaceSlotBindingsWithCredentialBindings do
  use Ecto.Migration

  def up do
    drop_if_exists table(:slot_bindings)

    create table(:credential_bindings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_definition_id,
          references(:workflow_definitions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, :string, null: false
      add :step_id, :string, null: false
      add :requirement_key, :string, null: false
      add :binding_data, :map, null: false, default: fragment("'{}'::jsonb")
      add :workos_organization_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :credential_bindings,
             [:user_id, :workflow_definition_id, :step_id, :requirement_key],
             name: :credential_bindings_user_definition_step_requirement_index
           )

    create index(:credential_bindings, [:workflow_definition_id, :step_id])
    create index(:credential_bindings, [:user_id, :workos_organization_id])
  end

  def down do
    drop_if_exists table(:credential_bindings)
  end
end
