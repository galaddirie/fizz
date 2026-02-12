defmodule Fizz.Repo.Migrations.CreateWorkflowPrimitives do
  use Ecto.Migration

  def change do
    create table(:workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :status, :string, null: false, default: "draft"
      add :public, :boolean, null: false, default: false
      add :current_version_tag, :string
      add :published_version_id, :binary_id

      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :user_id, references(:users, on_delete: :nothing, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflows, [:workspace_id])
    create index(:workflows, [:user_id])
    create index(:workflows, [:public])
    create index(:workflows, [:published_version_id])
    create index(:workflows, [:workspace_id, :user_id])

    create table(:workflow_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :version_tag, :string, null: false
      add :source_hash, :string, null: false
      add :steps, {:array, :map}, null: false, default: []
      add :connections, {:array, :map}, null: false, default: []
      add :groups, {:array, :map}, null: false, default: []
      add :changelog, :string
      add :published_at, :utc_datetime_usec

      add :published_by, references(:users, on_delete: :nilify_all, type: :binary_id)

      add :workflow_id, references(:workflows, on_delete: :delete_all, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:workflow_versions, [:workflow_id])
    create index(:workflow_versions, [:published_by])
    create unique_index(:workflow_versions, [:workflow_id, :version_tag])

    create table(:workflow_drafts, primary_key: false) do
      add :workflow_id, references(:workflows, on_delete: :delete_all, type: :binary_id),
        primary_key: true,
        null: false

      add :steps, {:array, :map}, null: false, default: []
      add :connections, {:array, :map}, null: false, default: []
      add :groups, {:array, :map}, null: false, default: []
      add :editor_state, :map, null: false, default: %{}

      add :settings, :map,
        null: false,
        default: %{"timeout_ms" => 300_000, "max_retries" => 3}

      timestamps(type: :utc_datetime_usec)
    end

    create table(:workflow_shares, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role, :string, null: false, default: "viewer"
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false

      add :workflow_id, references(:workflows, on_delete: :delete_all, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflow_shares, [:workflow_id])
    create index(:workflow_shares, [:user_id])
    create unique_index(:workflow_shares, [:user_id, :workflow_id])

    execute(
      """
      ALTER TABLE workflows
      ADD CONSTRAINT workflows_published_version_id_fkey
      FOREIGN KEY (published_version_id)
      REFERENCES workflow_versions(id)
      ON DELETE SET NULL
      """,
      """
      ALTER TABLE workflows
      DROP CONSTRAINT IF EXISTS workflows_published_version_id_fkey
      """
    )
  end
end
