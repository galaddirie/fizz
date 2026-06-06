defmodule Fizz.Fields.Definition do
  @moduledoc """
  Typed field declaration shared by operation inputs, credential selectors, and
  provider credential-creation forms.
  """

  @enforce_keys [:key, :type]
  defstruct [
    :key,
    :type,
    :label,
    :description,
    :default,
    :component,
    :placeholder,
    :autocomplete,
    :format,
    :minimum,
    :maximum,
    :resolver,
    :options,
    :display,
    :resource_locator,
    :resource_mapper,
    :credential,
    required?: false,
    secret?: false,
    write_only?: false,
    order: 100,
    depends_on: []
  ]

  @type field_type ::
          :string
          | :number
          | :boolean
          | :json
          | :select
          | :search
          | :credential
          | :resource_locator
          | :resource_mapper
          | :hidden
          | :password

  @type credential :: %{
          required(:provider) => String.t(),
          required(:auth_type) => :api_key | :oauth,
          required(:requirement_key) => String.t()
        }

  @type t :: %__MODULE__{
          key: String.t(),
          type: field_type(),
          label: String.t() | nil,
          description: String.t() | nil,
          required?: boolean(),
          default: term(),
          secret?: boolean(),
          write_only?: boolean(),
          component: String.t() | nil,
          placeholder: String.t() | nil,
          autocomplete: String.t() | nil,
          format: String.t() | nil,
          minimum: number() | nil,
          maximum: number() | nil,
          order: integer(),
          resolver: module() | nil,
          depends_on: [String.t()],
          options: [map()] | nil,
          display: map() | nil,
          resource_locator: map() | nil,
          resource_mapper: map() | nil,
          credential: credential() | nil
        }
end
