defmodule Fizz.Accounts.AuthProviderCatalog do
  @moduledoc """
  Account-context provider lookup boundary for auth persistence.
  """

  @callback resolve_provider_id_for_type(String.t(), :oauth | :api_key) ::
              {:ok, String.t()} | {:error, term()}
  @callback provider_for_type(String.t(), :oauth | :api_key) :: {:ok, map()} | {:error, term()}
  @callback provider(String.t()) :: {:ok, map()} | {:error, term()}
  @callback credential_secret_value(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
end
