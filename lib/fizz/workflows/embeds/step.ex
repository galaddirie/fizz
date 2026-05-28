defmodule Fizz.Workflows.Embeds.Step do
  use Ecto.Schema

  import Ecto.Changeset

  alias Fizz.Workflows.Embeds.Validation

  @max_name_length 160
  @primary_key false

  embedded_schema do
    field :id, :string
    field :type_id, :string
    field :name, :string
    field :config, :map, default: %{}
    field :position, :map, default: %{}
    field :notes, :string
  end

  @doc false
  def changeset(step, attrs) do
    step
    |> cast(attrs, [:id, :type_id, :name, :config, :position, :notes])
    |> validate_required([:id, :type_id, :name, :config])
    |> Validation.validate_uuid(:id)
    |> validate_length(:name, min: 1, max: @max_name_length)
    |> Validation.validate_map_field(:config)
    |> Validation.validate_map_field(:position)
  end
end
