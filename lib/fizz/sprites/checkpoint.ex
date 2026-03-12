defmodule Fizz.Sprites.Checkpoint do
  @moduledoc """
  Local representation of Sprite checkpoints.
  """

  use Fizz.Schema

  alias Fizz.Accounts.{Project, User}
  alias Fizz.Sprites.Sprite

  schema "sprite_checkpoints" do
    field :remote_checkpoint_id, :string
    field :comment, :string
    field :created_at_remote, :utc_datetime_usec

    belongs_to :sprite, Sprite
    belongs_to :project, Project
    belongs_to :created_by_user, User

    timestamps()
  end

  @doc false
  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, [
      :sprite_id,
      :project_id,
      :created_by_user_id,
      :remote_checkpoint_id,
      :comment,
      :created_at_remote
    ])
    |> validate_required([:sprite_id, :project_id, :remote_checkpoint_id])
    |> foreign_key_constraint(:sprite_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> unique_constraint(:remote_checkpoint_id,
      name: :sprite_checkpoints_sprite_id_remote_checkpoint_id_index
    )
  end
end
