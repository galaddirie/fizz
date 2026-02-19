defmodule Fizz.Workflows.Workflow do
  @moduledoc """
  Workflow schema.
  """
  use Fizz.Schema
  import Ecto.Changeset
  alias Fizz.Accounts.Workspace
  alias Fizz.Workflows.{WorkflowDraft, WorkflowVersion}

  defimpl LiveVue.Encoder, for: Ecto.Association.NotLoaded do
    def encode(_struct, _opts), do: nil
  end

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :description,
             :status,
             :current_version_tag,
             :published_version_id,
             :workspace_id,
             :user_id,
             :inserted_at,
             :updated_at
           ]}
  @derive {LiveVue.Encoder,
           only: [
             :id,
             :name,
             :description,
             :status,
             :current_version_tag,
             :published_version_id,
             :workspace_id,
             :user_id,
             :inserted_at,
             :updated_at,
             :draft,
             :workspace,
             :user,
             :published_version
           ]}

  schema "workflows" do
    field :name, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:draft, :active, :archived], default: :draft
    field :current_version_tag, :string

    belongs_to :published_version, WorkflowVersion
    belongs_to :workspace, Workspace
    belongs_to :user, Fizz.Accounts.User
    has_one :draft, WorkflowDraft
    has_many :versions, WorkflowVersion

    timestamps()
  end

  @doc """
  Builds a changeset for creating/updating a workflow.
  """
  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [
      :name,
      :description,
      :status,
      :current_version_tag,
      :published_version_id,
      :workspace_id,
      :user_id
    ])
    |> validate_required([:name, :workspace_id, :user_id])
    |> foreign_key_constraint(:workspace_id)
  end
end
