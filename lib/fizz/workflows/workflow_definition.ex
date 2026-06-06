defmodule Fizz.Workflows.WorkflowDefinition do
  use Fizz.Schema

  alias Fizz.Accounts.Project
  alias Fizz.Workflows.WorkflowDefinitionVersion

  schema "workflow_definitions" do
    field :workos_organization_id, :string
    field :name, :string
    field :description, :string
    field :created_by_user_id, :string
    field :archived_at, :utc_datetime_usec

    belongs_to :project, Project

    has_many :versions, WorkflowDefinitionVersion

    timestamps()
  end

  @doc false
  def changeset(definition, attrs) do
    definition
    |> cast(attrs, [
      :project_id,
      :workos_organization_id,
      :name,
      :description,
      :created_by_user_id,
      :archived_at
    ])
    |> validate_required([:project_id, :workos_organization_id, :name, :created_by_user_id])
    |> validate_length(:name, min: 1, max: 160)
    |> validate_length(:description, max: 5000)
    |> validate_length(:workos_organization_id, min: 3, max: 255)
    |> validate_length(:created_by_user_id, min: 1, max: 255)
    |> foreign_key_constraint(:project_id)
  end
end
