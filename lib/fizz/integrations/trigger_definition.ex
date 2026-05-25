defmodule Fizz.Integrations.TriggerDefinition do
  @moduledoc """
  Metadata-first definition for one integration trigger source.
  """

  @enforce_keys [:id, :step_type_id, :version, :provider, :integration, :module]
  defstruct [:id, :step_type_id, :version, :provider, :integration, :module]

  @type t :: %__MODULE__{
          id: String.t(),
          step_type_id: String.t(),
          version: pos_integer(),
          provider: String.t(),
          integration: String.t(),
          module: module()
        }
end
