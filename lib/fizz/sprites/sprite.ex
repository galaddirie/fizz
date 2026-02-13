defmodule Fizz.Sprites.Sprite do
  use Fizz.Schema

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  alias Fizz.Accounts.Workspace

  schema "sprites" do
    field :name, :string
    field :status, :string, default: "available"

    belongs_to :workspace, Workspace, type: :binary_id

    timestamps()
  end

  @doc false
  def changeset(sprite, attrs) do
    sprite
    |> cast(attrs, [:name, :status, :workspace_id])
    |> validate_required([:name, :status, :workspace_id])
    |> validate_length(:name, min: 2, max: 255)
    |> validate_length(:status, min: 2, max: 80)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint(:name)
  end
end
