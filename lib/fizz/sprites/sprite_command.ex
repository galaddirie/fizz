defmodule Fizz.Sprites.SpriteCommand do
  use Fizz.Schema

  alias Fizz.Accounts.User
  alias Fizz.Sprites.ManagedSprite

  @modes ~w(oneshot interactive)
  @statuses ~w(running completed failed)

  schema "sprite_commands" do
    field :command, :string
    field :args, {:array, :string}, default: []
    field :cwd, :string
    field :mode, :string, default: "oneshot"
    field :status, :string, default: "running"
    field :exit_code, :integer
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :managed_sprite, ManagedSprite
    belongs_to :actor_user, User

    timestamps()
  end

  @doc false
  def changeset(sprite_command, attrs) do
    sprite_command
    |> cast(attrs, [
      :managed_sprite_id,
      :actor_user_id,
      :command,
      :args,
      :cwd,
      :mode,
      :status,
      :exit_code,
      :started_at,
      :finished_at,
      :metadata
    ])
    |> validate_required([:managed_sprite_id, :actor_user_id, :command, :mode, :status])
    |> validate_length(:command, min: 1, max: 1000)
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:managed_sprite_id)
    |> foreign_key_constraint(:actor_user_id)
  end
end
