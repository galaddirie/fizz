defmodule Fizz.Workflows.Embeds.StepGroup do
  use Ecto.Schema

  import Ecto.Changeset

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
    |> validate_uuid(:id)
    |> validate_uuid_list(:step_ids)
    |> validate_map_field(:position)
    |> validate_number(:font_size, greater_than: 0)
  end

  defp validate_uuid(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case Ecto.UUID.cast(value) do
        {:ok, _uuid} -> []
        :error -> [{field, "must be a valid UUID"}]
      end
    end)
  end

  defp validate_uuid_list(changeset, field) do
    validate_change(changeset, field, fn ^field, values ->
      values
      |> Enum.reduce([], fn value, errors ->
        case Ecto.UUID.cast(value) do
          {:ok, _uuid} -> errors
          :error -> [{field, "must contain valid UUID values"} | errors]
        end
      end)
      |> Enum.uniq()
    end)
  end

  defp validate_map_field(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value) do
        []
      else
        [{field, "must be a map"}]
      end
    end)
  end
end
