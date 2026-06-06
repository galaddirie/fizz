defmodule Fizz.Workflows.Embeds.Connection do
  use Ecto.Schema

  import Ecto.Changeset

  @default_handle "main"
  @primary_key false

  embedded_schema do
    field :id, :string
    field :source_step_id, :string
    field :source_output, :string, default: @default_handle
    field :target_step_id, :string
    field :target_input, :string, default: @default_handle
  end

  @doc false
  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [:id, :source_step_id, :source_output, :target_step_id, :target_input])
    |> validate_required([:id, :source_step_id, :target_step_id])
    |> validate_uuid(:id)
    |> validate_uuid(:source_step_id)
    |> validate_uuid(:target_step_id)
  end

  defp validate_uuid(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case Ecto.UUID.cast(value) do
        {:ok, _uuid} -> []
        :error -> [{field, "must be a valid UUID"}]
      end
    end)
  end
end
