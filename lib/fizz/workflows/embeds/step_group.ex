defmodule Fizz.Workflows.Embeds.StepGroup do
  use Ecto.Schema

  import Ecto.Changeset

  alias Fizz.Workflows.Embeds.Validation

  @default_font_size 14
  @primary_key false

  embedded_schema do
    field :id, :string
    field :name, :string
    field :step_ids, {:array, :string}, default: []
    field :position, :map, default: %{}
    field :color, :string
    field :font_size, :integer, default: @default_font_size
    field :collapsed, :boolean, default: false
  end

  @doc false
  def changeset(step_group, attrs) do
    step_group
    |> cast(attrs, [:id, :name, :step_ids, :position, :color, :font_size, :collapsed])
    |> validate_required([:id, :name, :step_ids])
    |> Validation.validate_uuid(:id)
    |> Validation.validate_uuid_list(:step_ids)
    |> Validation.validate_map_field(:position)
    |> validate_number(:font_size, greater_than: 0)
  end
end
