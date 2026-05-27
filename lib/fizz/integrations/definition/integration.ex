defmodule Fizz.Integrations.Definition.Integration do
  @moduledoc """
  Struct form for product-level integration metadata.
  """

  @enforce_keys [:id, :display_name, :provider_id, :module]
  defstruct [:id, :display_name, :provider_id, :module, actions: [], triggers: []]

  @type t :: %__MODULE__{
          id: String.t(),
          display_name: String.t(),
          provider_id: String.t(),
          module: module(),
          actions: [String.t()],
          triggers: [module()]
        }
end
