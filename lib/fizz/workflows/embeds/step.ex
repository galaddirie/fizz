defmodule Fizz.Workflows.Embeds.Step do
  @moduledoc """
  Embedded schema for workflow steps.
  Shared between Workflow (mutable) and WorkflowVersion (immutable).

  ## Identity

  - `id` - Key-safe slug derived from display name (e.g., "http_request", "my_step_1")
  - `name` - User-facing display label (e.g., "HTTP Request", "My Step 1")
  - `type_id` - Reference to global step type registry

  The `id` is used everywhere as the primary instance identifier:
  - Runic component names
  - Expression variable keys (`steps.<step_id>.json`)
  - Connection references
  """
  @derive Jason.Encoder
  @derive {LiveVue.Encoder,
           only: [
             :id,
             :type_id,
             :name,
             :config,
             :position,
             :notes
           ]}
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  # Key-safe step ID pattern: lowercase alphanumeric + underscores
  @step_id_pattern ~r/^[a-z][a-z0-9_]*$/

  @type t :: %__MODULE__{
          id: String.t(),
          type_id: String.t(),
          name: String.t(),
          config: map(),
          position: map(),
          notes: String.t() | nil
        }

  embedded_schema do
    field :type_id, :string
    field :name, :string
    field :config, :map, default: %{}
    field :position, :map, default: %{}
    field :notes, :string
  end

  def changeset(step, attrs) do
    step
    |> cast(attrs, [:id, :type_id, :name, :config, :position, :notes])
    |> validate_required([:id, :type_id, :name])
    |> validate_format(:id, @step_id_pattern,
      message: "must be a key-safe identifier (lowercase, alphanumeric, underscores)"
    )
  end
end
