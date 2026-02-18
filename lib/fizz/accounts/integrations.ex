defmodule Fizz.Accounts.Integrations do
  @moduledoc """
  Compatibility facade for accounts-owned integration auth primitives.

  OAuth connection index operations are implemented in
  `Fizz.Accounts.OauthConnections` and API credential operations are implemented
  in `Fizz.Accounts.ApiCredentials`.
  """

  alias Fizz.Accounts.{ApiCredential, OauthConnection, Scope}
  alias Fizz.Accounts.ApiCredentials
  alias Fizz.Accounts.OauthConnections

  @doc """
  Returns the indexed auth connection for a user/provider in an organization.
  """
  @spec get_connection(Scope.t(), String.t(), String.t()) ::
          {:ok, OauthConnection.t()} | {:error, term()}
  defdelegate get_connection(scope, organization_id, provider), to: OauthConnections

  @doc """
  Upserts OAuth connection metadata for a provider in an organization.
  """
  @spec upsert_oauth_connection(Scope.t(), String.t(), String.t(), map()) ::
          {:ok, OauthConnection.t()} | {:error, term()}
  defdelegate upsert_oauth_connection(scope, organization_id, provider, status),
    to: OauthConnections

  @doc """
  Touches token fetch timestamp for an indexed provider connection.
  """
  @spec touch_connection_token_fetch(Scope.t(), String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate touch_connection_token_fetch(scope, organization_id, provider), to: OauthConnections

  @doc """
  Lists organization-scoped API credentials owned by the current user.
  """
  @spec list_credentials(Scope.t(), String.t()) ::
          {:ok, [ApiCredential.t()]} | {:error, term()}
  defdelegate list_credentials(scope, organization_id), to: ApiCredentials

  @doc """
  Creates an organization-scoped API credential and stores the secret in WorkOS Vault.
  """
  @spec create_credential(Scope.t(), String.t(), map()) ::
          {:ok, ApiCredential.t()} | {:error, term()}
  defdelegate create_credential(scope, organization_id, attrs), to: ApiCredentials

  @doc """
  Rotates the secret for an existing credential.
  """
  @spec rotate_credential(Scope.t(), String.t(), String.t(), map()) ::
          {:ok, ApiCredential.t()} | {:error, term()}
  defdelegate rotate_credential(scope, organization_id, credential_id, attrs), to: ApiCredentials

  @doc """
  Deletes an organization-scoped credential and its backing Vault object.
  """
  @spec delete_credential(Scope.t(), String.t(), String.t()) ::
          {:ok, ApiCredential.t()} | {:error, term()}
  defdelegate delete_credential(scope, organization_id, credential_id), to: ApiCredentials

  @doc """
  Resolves a credential for server-side execution-time use.
  """
  @spec resolve_credential_for_use(Scope.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_credential_for_use(scope, organization_id, provider, opts \\ []) do
    ApiCredentials.resolve_credential_for_use(scope, organization_id, provider, opts)
  end
end
