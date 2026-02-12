defmodule Fizz.Sprites.SpriteEvent do
  use Fizz.Schema

  alias Fizz.Accounts.User
  alias Fizz.Sprites.ManagedSprite

  @severities ~w(info warning error)

  schema "sprite_events" do
    field :event_type, :string
    field :severity, :string, default: "info"
    field :payload, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    belongs_to :managed_sprite, ManagedSprite
    belongs_to :actor_user, User

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(sprite_event, attrs) do
    sprite_event
    |> cast(attrs, [
      :managed_sprite_id,
      :actor_user_id,
      :event_type,
      :severity,
      :payload,
      :occurred_at
    ])
    |> validate_required([:event_type, :severity, :occurred_at])
    |> validate_length(:event_type, min: 2, max: 120)
    |> validate_inclusion(:severity, @severities)
    |> foreign_key_constraint(:managed_sprite_id)
    |> foreign_key_constraint(:actor_user_id)
  end
end
