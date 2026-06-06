defmodule Fizz.Integrations.Contracts.Provider do
  @moduledoc """
  Behaviour for integration auth providers.

  Providers own auth metadata, connection checking, token fetching, and network
  domains. Service-specific API calls belong in library clients.
  """

  alias Fizz.Accounts.Scope

  @type connection_status :: %{
          active: boolean(),
          scopes: [String.t()],
          missing_scopes: [String.t()],
          provider_metadata: map(),
          error: term() | nil
        }

  @type token_result :: %{
          required(:access_token) => String.t(),
          required(:expires_at) => String.t() | nil,
          required(:scopes) => [String.t()],
          required(:missing_scopes) => [String.t()],
          optional(:api_credential_id) => String.t(),
          optional(:credential_id) => String.t()
        }

  @callback provider_id() :: String.t()
  @callback display_name() :: String.t()
  @callback definition() :: Fizz.Integrations.Auth.ProviderDefinition.t()
  @callback check_connection(Scope.t(), organization_id :: String.t() | nil) ::
              {:ok, connection_status()} | {:error, term()}
  @callback fetch_token(Scope.t(), organization_id :: String.t() | nil) ::
              {:ok, token_result()} | {:error, term()}
  @callback network_domains() :: [String.t()]
end
