defmodule Fizz.Workflows.Embeds.Connection do
  @moduledoc """
  Embedded schema for workflow connections (edges between steps).
  Shared between Workflow (mutable) and WorkflowVersion (immutable).
  """
  @derive Jason.Encoder
  @derive {LiveVue.Encoder,
           only: [
             :id,
             :source_step_id,
             :source_output,
             :target_step_id,
             :target_input
           ]}

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{
          id: String.t(),
          source_step_id: String.t(),
          source_output: String.t(),
          target_step_id: String.t(),
          target_input: String.t()
        }

  embedded_schema do
    field :source_step_id, :string
    field :source_output, :string, default: "main"
    field :target_step_id, :string
    field :target_input, :string, default: "main"
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [:id, :source_step_id, :source_output, :target_step_id, :target_input])
    |> validate_required([:id, :source_step_id, :target_step_id])
  end
end
