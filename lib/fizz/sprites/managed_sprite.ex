defmodule Fizz.Sprites.ManagedSprite do
  use Fizz.Schema

  alias Fizz.Accounts.Workspace
  alias Fizz.Sprites.{SpriteCommand, SpriteEvent, SpriteSession}

  @url_auth_modes ~w(bearer public)

  schema "managed_sprites" do
    # name of the sprite in fly.io
    field :sprite_name, :string
    field :display_name, :string
    field :description, :string
    field :url, :string, virtual: true
    field :url_auth_mode, :string, default: "bearer"
    field :metadata, :map, default: %{}
    field :archived_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :workspace, Workspace

    has_many :commands, SpriteCommand
    has_many :events, SpriteEvent
    has_many :sprite_sessions, SpriteSession

    timestamps()
  end

  @doc false
  def changeset(managed_sprite, attrs) do
    managed_sprite
    |> cast(attrs, [
      :workspace_id,
      :sprite_name,
      :display_name,
      :description,
      :url_auth_mode,
      :metadata,
      :archived_at,
      :deleted_at
    ])
    |> validate_required([:workspace_id, :sprite_name, :display_name, :url_auth_mode])
    |> validate_length(:sprite_name, min: 3, max: 160)
    |> validate_length(:display_name, min: 2, max: 120)
    |> validate_length(:description, max: 280)
    |> validate_inclusion(:url_auth_mode, @url_auth_modes)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint(:sprite_name)
  end

  @doc false
  def create_changeset(managed_sprite, attrs) do
    managed_sprite
    |> changeset(attrs)
    |> put_default_metadata()
  end

  defp put_default_metadata(changeset) do
    metadata = Ecto.Changeset.get_field(changeset, :metadata) || %{}
    put_change(changeset, :metadata, metadata)
  end
end
