defmodule Fizz.Repo.Migrations.CreateWorkflowDefinitions do
  use Ecto.Migration

  def change do
    create table(:workflow_definitions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workos_organization_id, :string, null: false
      add :name, :string, null: false
      add :description, :text
      add :created_by_user_id, :string, null: false
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflow_definitions, [:project_id])
    create index(:workflow_definitions, [:workos_organization_id])

    create table(:workflow_definition_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_definition_id,
          references(:workflow_definitions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :version, :integer, null: false
      add :status, :string, null: false, default: "draft"
      add :steps, :map, null: false, default: fragment("'[]'::jsonb")
      add :connections, :map, null: false, default: fragment("'[]'::jsonb")
      add :step_groups, :map, null: false, default: fragment("'[]'::jsonb")
      add :viewport, :map, null: false, default: %{"x" => 0, "y" => 0, "zoom" => 1.0}
      add :settings, :map, null: false, default: %{}
      add :compiled_hash, :string
      add :published_at, :utc_datetime_usec
      add :published_by_user_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :workflow_definition_versions,
             :workflow_definition_versions_status_check,
             check: "status IN ('draft', 'published', 'archived')"
           )

    create unique_index(
             :workflow_definition_versions,
             [:workflow_definition_id, :version],
             name: :workflow_definition_versions_definition_version_index
           )
  end
end
