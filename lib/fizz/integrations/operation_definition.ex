defmodule Fizz.Integrations.OperationDefinition do
  @moduledoc """
  Metadata-first definition for one executable integration operation.
  """

  alias Fizz.Integrations.{CredentialRequirement, RetryPolicy}

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
    auth: [],
    default_config: %{},
    depends_on: %{},
    field_display: %{},
    input_schema: %{"type" => "object"},
    display: %{},
    config_schema: %{},
    output_schema: %{},
    resource_locators: %{},
    resource_mappers: %{},
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
          auth: [CredentialRequirement.t()],
          default_config: map(),
          depends_on: map(),
          field_display: map(),
          input_schema: map(),
          display: map(),
          config_schema: map(),
          output_schema: map(),
          resource_locators: map(),
          resource_mappers: map(),
          retry: RetryPolicy.t()
        }
end
