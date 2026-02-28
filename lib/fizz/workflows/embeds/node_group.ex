defmodule Fizz.Workflows.Embeds.NodeGroup do
  @moduledoc """
  Embedded schema for workflow node groups.

  A node group is a visual and execution boundary that exposes a single output.
  """
  @derive Jason.Encoder
  @derive {LiveVue.Encoder,
           only: [
             :id,
             :name,
             :step_ids,
             :output_step_id,
             :position,
             :color,
             :font_size,
             :collapsed
           ]}
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @default_font_size 14
  @min_font_size 10
  @max_font_size 32

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          step_ids: [String.t()],
          output_step_id: String.t(),
          position: map(),
          color: String.t() | nil,
          font_size: integer(),
          collapsed: boolean()
        }

  embedded_schema do
    field :name, :string
    field :step_ids, {:array, :string}, default: []
    field :output_step_id, :string
    field :position, :map, default: %{}
    field :color, :string
    field :font_size, :integer, default: @default_font_size
    field :collapsed, :boolean, default: false
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :id,
      :name,
      :step_ids,
      :output_step_id,
      :position,
      :color,
      :font_size,
      :collapsed
    ])
    |> validate_required([:id, :name, :step_ids, :output_step_id])
    |> validate_number(:font_size,
      greater_than_or_equal_to: @min_font_size,
      less_than_or_equal_to: @max_font_size
    )
    |> validate_output_step_in_group()
  end

  defp validate_output_step_in_group(changeset) do
    output_step_id = get_field(changeset, :output_step_id)
    step_ids = get_field(changeset, :step_ids) || []

    if output_step_id && output_step_id not in step_ids do
      add_error(changeset, :output_step_id, "must be one of the group's steps")
    else
      changeset
    end
  end
end
