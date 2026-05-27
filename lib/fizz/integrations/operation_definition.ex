defmodule Fizz.Integrations.OperationDefinition do
  @moduledoc """
  Metadata-first definition for one executable integration operation.
  """

  alias Fizz.Fields.Definition, as: FieldDefinition
  alias Fizz.Integrations.RetryPolicy

  @enforce_keys [
    :id,
    :step_type_id,
    :version,
    :provider,
    :integration,
    :module,
    :display,
    :config_schema,
    :output_schema
  ]
  defstruct [
    :id,
    :step_type_id,
    :version,
    :provider,
    :integration,
    :kind,
    :module,
    default_config: %{},
    fields: [],
    input_schema: %{"type" => "object"},
    display: %{},
    config_schema: %{},
    output_schema: %{},
    retry: %RetryPolicy{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          step_type_id: String.t(),
          version: pos_integer(),
          provider: String.t(),
          integration: String.t(),
          kind: :action | :trigger,
          module: module(),
          default_config: map(),
          fields: [FieldDefinition.t()],
          input_schema: map(),
          display: map(),
          config_schema: map(),
          output_schema: map(),
          retry: RetryPolicy.t()
        }
end
