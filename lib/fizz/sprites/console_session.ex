defmodule Fizz.Sprites.ConsoleSession do
  @moduledoc """
  Interactive console lease metadata.
  """

  use Fizz.Schema

  alias Fizz.Accounts.{Project, User}
  alias Fizz.Sprites.Sprite

  @states [:active, :closed, :errored]

  schema "sprite_console_sessions" do
    field :remote_session_id, :string
    field :state, Ecto.Enum, values: @states, default: :active
    field :opened_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :close_reason, :string
    field :rows, :integer, default: 24
    field :cols, :integer, default: 80

    belongs_to :sprite, Sprite
    belongs_to :project, Project
    belongs_to :opened_by_user, User

    timestamps()
  end

  @doc false
  def changeset(console_session, attrs) do
    console_session
    |> cast(attrs, [
      :sprite_id,
      :project_id,
      :opened_by_user_id,
      :remote_session_id,
      :state,
      :opened_at,
      :closed_at,
      :close_reason,
      :rows,
      :cols
    ])
    |> validate_required([:sprite_id, :project_id, :state])
    |> validate_number(:rows, greater_than: 0)
    |> validate_number(:cols, greater_than: 0)
    |> foreign_key_constraint(:sprite_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:opened_by_user_id)
  end
end
