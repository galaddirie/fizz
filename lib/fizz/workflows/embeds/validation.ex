defmodule Fizz.Workflows.Embeds.Validation do
  @moduledoc false

  import Ecto.Changeset

  def validate_uuid(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case Ecto.UUID.cast(value) do
        {:ok, _uuid} -> []
        :error -> [{field, "must be a valid UUID"}]
      end
    end)
  end

  def validate_uuid_list(changeset, field) do
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

  def validate_map_field(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value) do
        []
      else
        [{field, "must be a map"}]
      end
    end)
  end
end
