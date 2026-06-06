defmodule Fizz.Accounts.ProjectMembership do
  @moduledoc """
  Links a user to a project with a specific role.

  Three roles are available: `:admin` (full control), `:member` (standard
  access), and `:viewer` (read-only). The default role is `:viewer`.

  A user may hold at most one membership per project (enforced by a unique
  constraint). The optional `access_purpose` field documents why the user
  was granted access.
  """

  use Fizz.Schema

  alias Fizz.Accounts.{Project, User}

  @roles [:admin, :member, :viewer]

  schema "project_memberships" do
    field :role, Ecto.Enum, values: @roles, default: :viewer
    field :access_purpose, :string

    belongs_to :project, Project
    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :access_purpose])
    |> validate_required([:role])
    |> validate_length(:access_purpose, max: 280)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id, name: :project_memberships_project_id_user_id_index)
  end
end
