defmodule Fizz.Workspaces.Checkpoint do
  @moduledoc """
  Local representation of Workspace checkpoints.
  """

  use Fizz.Schema

  alias Fizz.Accounts.{Project, User}
  alias Fizz.Workspaces.Workspace

  schema "workspace_checkpoints" do
    field :remote_checkpoint_id, :string
    field :comment, :string
    field :created_at_remote, :utc_datetime_usec

    belongs_to :workspace, Workspace
    belongs_to :project, Project
    belongs_to :created_by_user, User

    timestamps()
  end

  @doc false
  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, [
      :workspace_id,
      :project_id,
      :created_by_user_id,
      :remote_checkpoint_id,
      :comment,
      :created_at_remote
    ])
    |> validate_required([:workspace_id, :project_id, :remote_checkpoint_id])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> unique_constraint(:remote_checkpoint_id,
      name: :workspace_checkpoints_workspace_id_remote_checkpoint_id_index
    )
  end
end
