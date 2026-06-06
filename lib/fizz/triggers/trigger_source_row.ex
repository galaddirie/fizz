defmodule Fizz.Triggers.TriggerSourceRow do
  @moduledoc """
  Durable row snapshot for polling integrations that detect row-level changes.
  """

  use Fizz.Schema

  alias Fizz.Triggers.TriggerSource

  @type t :: %__MODULE__{}

  schema "trigger_source_rows" do
    field :row_key, :string
    field :row_number, :integer
    field :row_hash, :string
    field :values, :map, default: %{}
    field :raw_values, {:array, :string}, default: []
    field :last_seen_at, :utc_datetime_usec
    field :last_changed_at, :utc_datetime_usec

    belongs_to :trigger_source, TriggerSource

    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :trigger_source_id,
      :row_key,
      :row_number,
      :row_hash,
      :values,
      :raw_values,
      :last_seen_at,
      :last_changed_at
    ])
    |> validate_required([
      :trigger_source_id,
      :row_key,
      :row_number,
      :row_hash,
      :values,
      :raw_values,
      :last_seen_at,
      :last_changed_at
    ])
    |> validate_length(:row_key, min: 1, max: 512)
    |> validate_length(:row_hash, min: 1, max: 128)
    |> validate_number(:row_number, greater_than: 0)
    |> foreign_key_constraint(:trigger_source_id)
    |> unique_constraint([:trigger_source_id, :row_key],
      name: :trigger_source_rows_source_row_key_index
    )
  end
end
