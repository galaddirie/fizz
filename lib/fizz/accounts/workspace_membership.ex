defmodule Fizz.Accounts.WorkspaceMembership do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fizz.Accounts.{User, Workspace}

  @roles [:admin, :member, :viewer]

  schema "workspace_memberships" do
    field :role, Ecto.Enum, values: @roles, default: :viewer
    field :access_purpose, :string

    belongs_to :workspace, Workspace
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :access_purpose])
    |> validate_required([:role])
    |> validate_length(:access_purpose, max: 280)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id, name: :workspace_memberships_workspace_id_user_id_index)
  end
end
