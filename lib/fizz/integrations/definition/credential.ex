defmodule Fizz.Integrations.Definition.Credential do
  @moduledoc """
  Struct form for credential metadata in the unified catalog.
  """

  @enforce_keys [:id, :provider, :auth_type, :display]
  defstruct [:id, :provider, :auth_type, :display, ui_schema: %{}, test: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          provider: String.t(),
          auth_type: :oauth | :api_key,
          display: map(),
          ui_schema: map(),
          test: map() | nil
        }
end
