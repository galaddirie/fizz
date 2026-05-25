defmodule Fizz.Integrations.Definition.Provider do
  @moduledoc """
  Struct form for provider metadata in the unified catalog.
  """

  @enforce_keys [:id, :label, :type]
  defstruct [:id, :label, :type, :logo_path, custom: false, module: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          type: :oauth | :api_key,
          logo_path: String.t() | nil,
          custom: boolean(),
          module: module() | nil
        }
end
