defmodule Fizz.Workflows.WorkflowShare do
  @moduledoc """
  Workflow sharing schema for managing access to workflows by other users.

  This schema persists sharing relationships between workflows and users.
  Permission checks should be performed through `Fizz.Accounts.Scope` or
  `Fizz.Workflows.Sharing`, not by querying this schema directly.

  ## Roles

  - `:viewer` - Can view the workflow and its executions, but cannot edit
  - `:editor` - Can view and edit the workflow, including the draft
  - `:owner` - Full access, equivalent to the original creator

  Note: The workflow's actual owner (via `workflow.user_id`) implicitly has
  owner-level access without needing a share record.

  """
  use Fizz.Schema

  alias Fizz.Workflows.Workflow
  alias Fizz.Accounts.User

  @type role :: :viewer | :editor | :owner
  @valid_roles [:viewer, :editor, :owner]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          role: role(),
          user_id: Ecto.UUID.t(),
          workflow_id: Ecto.UUID.t(),
          user: User.t() | Ecto.Association.NotLoaded.t(),
          workflow: Workflow.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "workflow_shares" do
    field :role, Ecto.Enum, values: @valid_roles, default: :viewer

    belongs_to :user, User
    belongs_to :workflow, Workflow

    timestamps()
  end

  @doc """
  Changeset for creating or updating workflow shares.

  ## Required fields

  - `:role` - The permission level (`:viewer`, `:editor`, or `:owner`)
  - `:user_id` - The user being granted access
  - `:workflow_id` - The workflow to share

  ## Validations

  - Role must be one of the valid roles
  - User/workflow combination must be unique
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(workflow_share, attrs) do
    workflow_share
    |> cast(attrs, [:role, :user_id, :workflow_id])
    |> validate_required([:role, :user_id, :workflow_id])
    |> validate_inclusion(:role, @valid_roles)
    |> unique_constraint([:user_id, :workflow_id],
      name: :workflow_shares_user_id_workflow_id_index,
      message: "user already has access to this workflow"
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:workflow_id)
  end

  @doc """
  Returns the valid roles for workflow sharing.
  """
  @spec valid_roles() :: [role()]
  def valid_roles, do: @valid_roles

  @doc """
  Checks if a role grants edit permissions.
  """
  @spec can_edit?(role()) :: boolean()
  def can_edit?(role) when role in [:editor, :owner], do: true
  def can_edit?(_), do: false

  @doc """
  Checks if a role grants view permissions.
  """
  @spec can_view?(role()) :: boolean()
  def can_view?(role) when role in @valid_roles, do: true
  def can_view?(_), do: false
end
