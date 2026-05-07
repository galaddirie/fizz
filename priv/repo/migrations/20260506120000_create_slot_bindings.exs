defmodule Fizz.Repo.Migrations.CreateSlotBindings do
  use Ecto.Migration

  def change do
    create table(:slot_bindings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_definition_id,
          references(:workflow_definitions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, :string, null: false
      add :step_id, :string, null: false
      add :slot_key, :string, null: false
      add :kind, :string, null: false
      add :binding_data, :map, null: false, default: fragment("'{}'::jsonb")
      add :workos_organization_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :slot_bindings,
             [:user_id, :workflow_definition_id, :step_id, :slot_key],
             name: :slot_bindings_user_definition_step_slot_index
           )

    create index(:slot_bindings, [:workflow_definition_id, :step_id])
    create index(:slot_bindings, [:user_id, :workos_organization_id])
  end
end
