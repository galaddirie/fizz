defmodule Fizz.Integrations.CredentialRequirement do
  @moduledoc """
  Declares one credential slot required by an integration operation.
  """

  @enforce_keys [:key, :provider, :auth_type]
  defstruct [:key, :provider, :auth_type, slot_key: "auth", required: true, label: nil]

  @type auth_type :: :oauth | :api_key
  @type t :: %__MODULE__{
          key: String.t(),
          provider: String.t(),
          auth_type: auth_type(),
          slot_key: String.t(),
          required: boolean(),
          label: String.t() | nil
        }
end
