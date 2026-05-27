defmodule Fizz.Integrations.Catalog.Definitions.Integration do
  @moduledoc """
  Struct form for product-level integration metadata.
  """

  @enforce_keys [:id, :display_name, :module]
  defstruct [
    :id,
    :display_name,
    :provider_id,
    :module,
    actions: [],
    triggers: [],
    step_modules: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          display_name: String.t(),
          provider_id: String.t() | nil,
          module: module(),
          actions: [String.t()],
          triggers: [module()],
          step_modules: [module()]
        }
end
