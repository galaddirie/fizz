defmodule Fizz.Sprites.Service do
  @moduledoc """
  Service definition persisted per sprite.
  """

  use Fizz.Schema

  alias Fizz.Accounts.Workspace
  alias Fizz.Sprites.Sprite

  @states [:stopped, :running, :error]

  schema "sprite_services" do
    field :name, :string
    field :cmd, :string
    field :args, {:array, :string}, default: []
    field :needs, {:array, :string}, default: []
    field :status, Ecto.Enum, values: @states, default: :stopped
    field :published, :boolean, default: false
    field :metadata, :map, default: %{}
    field :last_started_at, :utc_datetime_usec
    field :last_stopped_at, :utc_datetime_usec

    belongs_to :sprite, Sprite
    belongs_to :workspace, Workspace

    timestamps()
  end

  @doc false
  def changeset(service, attrs) do
    service
    |> cast(attrs, [
      :sprite_id,
      :workspace_id,
      :name,
      :cmd,
      :args,
      :needs,
      :status,
      :published,
      :metadata,
      :last_started_at,
      :last_stopped_at
    ])
    |> validate_required([:sprite_id, :workspace_id, :name])
    |> validate_length(:name, min: 2, max: 120)
    |> foreign_key_constraint(:sprite_id)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint(:name, name: :sprite_services_sprite_id_name_index)
  end
end
