defmodule Fizz.Workflows.Embeds.Step do
  use Ecto.Schema

  import Ecto.Changeset

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
    |> validate_uuid(:id)
    |> validate_length(:name, min: 1, max: @max_name_length)
    |> validate_map_field(:config)
    |> validate_map_field(:position)
  end

  defp validate_uuid(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case Ecto.UUID.cast(value) do
        {:ok, _uuid} -> []
        :error -> [{field, "must be a valid UUID"}]
      end
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
