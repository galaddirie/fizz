defmodule Fizz.Sprites.SpriteSession do
  use Fizz.Schema

  alias Fizz.Sprites.{ManagedSprite, SpriteConsoleChunk}
  alias Fizz.Accounts.User

  @states ~w(starting attached grace_detaching detached ended failed)

  schema "sprite_sessions" do
    belongs_to :managed_sprite, ManagedSprite
    belongs_to :owner_user, User

    field :pane_id, :string
    field :provider_session_id, :string
    field :interactive_command, :string
    field :tty, :boolean, default: true
    field :state, :string, default: "starting"
    field :generation, :integer, default: 1
    field :lease_client_id, :string
    field :lease_acquired_at, :utc_datetime_usec
    field :grace_started_at, :utc_datetime_usec
    field :last_seq, :integer, default: 0
    field :last_activity_at, :utc_datetime_usec
    field :closed_reason, :string
    field :exit_code, :integer
    field :metadata, :map, default: %{}

    has_many :chunks, SpriteConsoleChunk

    timestamps()
  end

  @doc false
  def changeset(sprite_session, attrs) do
    sprite_session
    |> cast(attrs, [
      :managed_sprite_id,
      :owner_user_id,
      :pane_id,
      :provider_session_id,
      :interactive_command,
      :tty,
      :state,
      :generation,
      :lease_client_id,
      :lease_acquired_at,
      :grace_started_at,
      :last_seq,
      :last_activity_at,
      :closed_reason,
      :exit_code,
      :metadata
    ])
    |> validate_required([
      :managed_sprite_id,
      :owner_user_id,
      :pane_id,
      :interactive_command,
      :tty,
      :state,
      :generation,
      :last_seq
    ])
    |> validate_inclusion(:state, @states)
    |> validate_number(:generation, greater_than_or_equal_to: 1)
    |> validate_number(:last_seq, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:managed_sprite_id)
    |> foreign_key_constraint(:owner_user_id)
    |> unique_constraint(:provider_session_id)
  end
end
