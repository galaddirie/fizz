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
             :collapsed
           ]}
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          step_ids: [String.t()],
          output_step_id: String.t(),
          position: map(),
          color: String.t() | nil,
          collapsed: boolean()
        }

  embedded_schema do
    field :name, :string
    field :step_ids, {:array, :string}, default: []
    field :output_step_id, :string
    field :position, :map, default: %{}
    field :color, :string
    field :collapsed, :boolean, default: false
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:id, :name, :step_ids, :output_step_id, :position, :color, :collapsed])
    |> validate_required([:id, :name, :step_ids, :output_step_id])
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
