defmodule Fizz.Slots.CredentialSlot do
  @moduledoc """
  Builder for credential slot declarations and config schema entries.

  Use this beside the step or integration that owns the credential requirement
  instead of registering step IDs in a shared table.
  """

  alias Fizz.Slots.Field

  @enforce_keys [:provider, :auth_type]
  defstruct [:provider, :auth_type, slot_key: "auth"]

  @type auth_type :: :api_key | :oauth
  @type t :: %__MODULE__{
          provider: String.t(),
          auth_type: auth_type(),
          slot_key: String.t()
        }

  @spec oauth(String.t(), keyword()) :: t()
  def oauth(provider, opts \\ []), do: new(provider, :oauth, opts)

  @spec api_key(String.t(), keyword()) :: t()
  def api_key(provider, opts \\ []), do: new(provider, :api_key, opts)

  @spec new(String.t(), auth_type(), keyword()) :: t()
  def new(provider, auth_type, opts \\ [])
      when is_binary(provider) and auth_type in [:api_key, :oauth] and is_list(opts) do
    %__MODULE__{
      provider: provider,
      auth_type: auth_type,
      slot_key: Keyword.get(opts, :slot_key, "auth")
    }
  end

  @spec declaration(t(), keyword()) :: map()
  def declaration(%__MODULE__{} = slot, opts \\ []) do
    Field.credential_declaration(slot.provider, slot.auth_type, slot_opts(slot, opts))
  end

  @spec schema(t(), keyword()) :: map()
  def schema(%__MODULE__{} = slot, opts \\ []) do
    Field.credential_schema(slot.provider, slot.auth_type, slot_opts(slot, opts))
  end

  defp slot_opts(%__MODULE__{slot_key: slot_key}, opts) do
    Keyword.put_new(opts, :slot_key, slot_key)
  end
end
