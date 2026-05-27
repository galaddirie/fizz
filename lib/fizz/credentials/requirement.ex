defmodule Fizz.Credentials.Requirement do
  @moduledoc """
  Builder for credential declarations and config schema entries.

  Use this beside the step or integration that owns the credential requirement
  instead of declaring it through generic slot metadata.
  """

  alias Fizz.Credentials.Field

  @enforce_keys [:provider, :auth_type]
  defstruct [:provider, :auth_type, requirement_key: "auth"]

  @type auth_type :: :api_key | :oauth
  @type t :: %__MODULE__{
          provider: String.t(),
          auth_type: auth_type(),
          requirement_key: String.t()
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
      requirement_key: Keyword.get(opts, :requirement_key, "auth")
    }
  end

  @spec declaration(t(), keyword()) :: map()
  def declaration(%__MODULE__{} = requirement, opts \\ []) do
    Field.credential_declaration(
      requirement.provider,
      requirement.auth_type,
      requirement_opts(requirement, opts)
    )
  end

  @spec schema(t(), keyword()) :: map()
  def schema(%__MODULE__{} = requirement, opts \\ []) do
    Field.credential_schema(
      requirement.provider,
      requirement.auth_type,
      requirement_opts(requirement, opts)
    )
  end

  @spec declaration?(term()) :: boolean()
  def declaration?(value), do: Field.declaration?(value)

  defp requirement_opts(%__MODULE__{requirement_key: requirement_key}, opts) do
    Keyword.put_new(opts, :requirement_key, requirement_key)
  end
end
