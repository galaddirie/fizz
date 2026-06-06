defmodule Fizz.Integrations.Catalog.Definitions.Resolver do
  @moduledoc """
  Metadata-first definition for one dynamic integration resolver.
  """

  @enforce_keys [:id, :module]
  defstruct [:id, :module, provider: nil, integration: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          module: module(),
          provider: String.t() | nil,
          integration: String.t() | nil
        }
end
