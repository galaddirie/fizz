defmodule Fizz.Workflows.Workflow do
  @moduledoc """
  Workflow schema.
  """
  use Fizz.Schema
  import Ecto.Query
  import Ecto.Changeset
  alias Fizz.Accounts.Workspace
  alias Fizz.Workflows.{WorkflowDraft, WorkflowVersion, WorkflowShare}

  defimpl LiveVue.Encoder, for: Ecto.Association.NotLoaded do
    def encode(_struct, _opts), do: nil
  end

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :description,
             :status,
             :public,
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
             :public,
             :current_version_tag,
             :published_version_id,
             :workspace_id,
             :user_id,
             :inserted_at,
             :updated_at,
             :draft,
             :user,
             :published_version
           ]}

  schema "workflows" do
    field :name, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:draft, :active, :archived], default: :draft
    field :public, :boolean, default: false
    field :current_version_tag, :string

    belongs_to :workspace, Workspace
    belongs_to :published_version, WorkflowVersion
    belongs_to :user, Fizz.Accounts.User
    has_one :draft, WorkflowDraft
    has_many :versions, WorkflowVersion
    has_many :shares, WorkflowShare

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
      :public,
      :current_version_tag,
      :published_version_id,
      :workspace_id,
      :user_id
    ])
    |> validate_required([:name, :user_id, :workspace_id])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Filters workflows by WorkOS organization id.
  """
  @spec for_organization(Ecto.Queryable.t(), String.t()) :: Ecto.Query.t()
  def for_organization(queryable \\ __MODULE__, organization_id)
      when is_binary(organization_id) do
    workspace_ids_query =
      from ws in Workspace,
        where: ws.workos_organization_id == ^organization_id,
        select: ws.id

    from w in queryable, where: w.workspace_id in subquery(workspace_ids_query)
  end

  @doc """
  Filters workflows by workspace id.
  """
  @spec for_workspace(Ecto.Queryable.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def for_workspace(queryable \\ __MODULE__, workspace_id) when is_binary(workspace_id) do
    from w in queryable, where: w.workspace_id == ^workspace_id
  end

  @doc """
  Filters workflows by owner user id.
  """
  @spec owned_by(Ecto.Queryable.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def owned_by(queryable \\ __MODULE__, user_id) when is_binary(user_id) do
    from w in queryable, where: w.user_id == ^user_id
  end
end
