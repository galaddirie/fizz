defmodule Fizz.Integrations do
  @moduledoc """
  Integrations orchestration layer.

  This module owns provider definitions and execution-time auth routing while
  delegating credential/connection persistence to `Fizz.Accounts.ExternalAuth`.
  """

  alias Fizz.Accounts
  alias Fizz.Accounts.{OauthConnection, Scope}
  alias Fizz.Accounts.ExternalAuth, as: AccountExternalAuth
  alias Fizz.Integrations.CredentialRef
  alias Fizz.Integrations.ProviderCatalog

  @doc """
  Returns the OAuth provider module for the given provider ID.
  """
  @spec provider_module(String.t()) :: {:ok, module()} | {:error, term()}
  def provider_module(provider) when is_binary(provider) do
    ProviderCatalog.oauth_provider_module(provider)
  end

  @doc """
  Returns the indexed connection record for a provider in the project's organization.
  """
  @spec get_connection(Scope.t(), String.t(), String.t()) ::
          {:ok, OauthConnection.t()} | {:error, term()}
  def get_connection(%Scope{} = scope, project_id, provider) do
    with {:ok, resolved_scope} <- resolve_project_scope(scope, project_id),
         organization_id when is_binary(organization_id) <- resolved_scope.organization_id do
      AccountExternalAuth.get_connection(resolved_scope, organization_id, provider)
    end
  end

  @doc """
  Checks live OAuth connection status and syncs the account-owned connection index.
  """
  @spec check_and_sync_connection(Scope.t(), String.t(), String.t()) ::
          {:ok, OauthConnection.t()} | {:error, term()}
  def check_and_sync_connection(%Scope{} = scope, project_id, provider) do
    with {:ok, provider_mod} <- provider_module(provider),
         {:ok, resolved_scope} <- resolve_project_scope(scope, project_id),
         organization_id when is_binary(organization_id) <- resolved_scope.organization_id,
         {:ok, status} <- provider_mod.check_connection(resolved_scope, organization_id) do
      AccountExternalAuth.upsert_oauth_connection(
        resolved_scope,
        organization_id,
        provider,
        status
      )
    end
  end

  @doc """
  Lists metadata-only credential options for workflow editor credential selectors.
  """
  @spec list_credential_options(Scope.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_credential_options(%Scope{} = scope, project_id, opts \\ []) do
    with {:ok, resolved_scope} <- resolve_project_scope(scope, project_id),
         organization_id when is_binary(organization_id) <- resolved_scope.organization_id do
      AccountExternalAuth.list_credential_options(resolved_scope, organization_id, opts)
    end
  end

  @doc """
  Fetches execution-time auth material for a sprite.

  OAuth providers return a short-lived access token. API-key providers return the
  decrypted API key from WorkOS Vault under the same token-like response shape.
  """
  @spec fetch_token_for_sprite(Scope.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def fetch_token_for_sprite(%Scope{} = scope, project_id, provider) do
    with {:ok, auth} <- resolve_auth_for_execution(scope, project_id, provider) do
      case auth.auth_method do
        :oauth ->
          _ =
            AccountExternalAuth.touch_connection_token_fetch(
              auth.scope,
              auth.organization_id,
              auth.provider
            )

          {:ok, auth.token_result}

        :api_key ->
          {:ok,
           %{
             access_token: auth.api_key,
             expires_at: nil,
             scopes: [],
             missing_scopes: []
           }}
      end
    end
  end

  @doc """
  Resolves provider auth for execution.
  """
  @spec resolve_auth_for_execution(Scope.t(), String.t(), String.t()) ::
          {:ok,
           %{
             auth_method: :oauth,
             provider: String.t(),
             token_result: map(),
             scope: Scope.t(),
             organization_id: String.t()
           }}
          | {:ok,
             %{
               auth_method: :api_key,
               provider: String.t(),
               api_key: String.t(),
               api_credential_id: String.t()
             }}
          | {:error, term()}
  def resolve_auth_for_execution(%Scope{} = scope, project_id, provider) do
    with {:ok, resolved_scope} <- resolve_project_scope(scope, project_id),
         organization_id when is_binary(organization_id) <- resolved_scope.organization_id,
         {:ok, auth_method, normalized_provider} <-
           resolve_provider_for_execution(provider) do
      case auth_method do
        :oauth ->
          fetch_oauth_token(resolved_scope, organization_id, normalized_provider)

        :api_key ->
          fetch_api_key_token(resolved_scope, organization_id, normalized_provider)
      end
    end
  end

  @doc """
  Resolves provider auth for execution using an explicit credential reference.
  """
  @spec resolve_auth_for_execution(Scope.t(), String.t(), String.t(), map()) ::
          {:ok,
           %{
             auth_method: :oauth,
             provider: String.t(),
             token_result: map(),
             scope: Scope.t(),
             organization_id: String.t(),
             oauth_connection_id: String.t()
           }}
          | {:ok,
             %{
               auth_method: :api_key,
               provider: String.t(),
               api_key: String.t(),
               api_credential_id: String.t()
             }}
          | {:error, term()}
  def resolve_auth_for_execution(%Scope{} = scope, project_id, provider, credential_ref)
      when is_binary(provider) and is_map(credential_ref) do
    with {:ok, resolved_scope} <- resolve_project_scope(scope, project_id),
         organization_id when is_binary(organization_id) <- resolved_scope.organization_id,
         {:ok, normalized_ref} <- CredentialRef.normalize(credential_ref),
         :ok <- CredentialRef.ensure_owner(normalized_ref, resolved_scope.user.id),
         :ok <- ensure_ref_provider_matches_requested(provider, normalized_ref["provider"]) do
      case normalized_ref["auth_type"] do
        "oauth" ->
          fetch_oauth_token_with_ref(
            resolved_scope,
            organization_id,
            normalized_ref["provider"],
            normalized_ref
          )

        "api_key" ->
          fetch_api_key_token_with_ref(
            resolved_scope,
            organization_id,
            normalized_ref["provider"],
            normalized_ref
          )

        _ ->
          {:error, :invalid_credential_ref_auth_type}
      end
    end
  end

  @doc """
  Lists repos from an OAuth provider.
  """
  @spec list_repos(Scope.t(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_repos(%Scope{} = scope, project_id, provider, opts \\ []) do
    with {:ok, provider_mod} <- provider_module(provider),
         {:ok, resolved_scope} <- resolve_project_scope(scope, project_id),
         organization_id when is_binary(organization_id) <- resolved_scope.organization_id do
      opts = Keyword.put(opts, :organization_id, organization_id)
      provider_mod.list_repos(resolved_scope, opts)
    end
  end

  @doc """
  Creates a pull request via an OAuth provider.
  """
  @spec create_pull_request(Scope.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def create_pull_request(%Scope{} = scope, project_id, provider, params) do
    with {:ok, provider_mod} <- provider_module(provider),
         {:ok, resolved_scope} <- resolve_project_scope(scope, project_id),
         organization_id when is_binary(organization_id) <- resolved_scope.organization_id do
      provider_mod.create_pull_request(
        resolved_scope,
        Map.put(params, "organization_id", organization_id)
      )
    end
  end

  @doc """
  Returns required network domains for a provider.
  """
  @spec network_domains_for_provider(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def network_domains_for_provider(provider) do
    with {:ok, provider_mod} <- provider_module_for_network_domains(provider) do
      {:ok, provider_mod.network_domains()}
    end
  end

  @doc """
  Resolves a project-scoped caller for integration operations.
  """
  @spec resolve_project_scope(Scope.t(), String.t()) :: {:ok, Scope.t()} | {:error, term()}
  def resolve_project_scope(scope, project_id) do
    Accounts.build_scope_for_project(scope, project_id)
  end

  defp fetch_oauth_token(resolved_scope, organization_id, provider) do
    with {:ok, provider_mod} <- provider_module(provider),
         {:ok, token_result} <- provider_mod.fetch_token(resolved_scope, organization_id) do
      {:ok,
       %{
         auth_method: :oauth,
         provider: provider,
         token_result: token_result,
         scope: resolved_scope,
         organization_id: organization_id
       }}
    end
  end

  defp fetch_oauth_token_with_ref(resolved_scope, organization_id, provider, credential_ref) do
    with {:ok, normalized_provider} <-
           ProviderCatalog.resolve_provider_id_for_type(provider, :oauth),
         {:ok, provider_mod} <- provider_module(normalized_provider),
         {:ok, oauth_connection_id} <- CredentialRef.id(credential_ref),
         {:ok, _connection} <-
           AccountExternalAuth.resolve_connection_for_use(
             resolved_scope,
             organization_id,
             normalized_provider,
             oauth_connection_id: oauth_connection_id
           ),
         {:ok, token_result} <- provider_mod.fetch_token(resolved_scope, organization_id) do
      _ =
        AccountExternalAuth.touch_connection_token_fetch(
          resolved_scope,
          organization_id,
          normalized_provider
        )

      {:ok,
       %{
         auth_method: :oauth,
         provider: normalized_provider,
         token_result: token_result,
         scope: resolved_scope,
         organization_id: organization_id,
         oauth_connection_id: oauth_connection_id
       }}
    end
  end

  defp fetch_api_key_token(resolved_scope, organization_id, provider) do
    case ProviderCatalog.api_key_provider_module(provider) do
      {:ok, provider_mod} ->
        with {:ok, %{access_token: api_key} = token_result}
             when is_binary(api_key) <-
               provider_mod.fetch_token(resolved_scope, organization_id),
             api_credential_id when is_binary(api_credential_id) <-
               token_result[:api_credential_id] || token_result[:credential_id] do
          {:ok,
           %{
             auth_method: :api_key,
             provider: provider,
             api_key: api_key,
             api_credential_id: api_credential_id
           }}
        else
          {:ok, _token_result} ->
            {:error, :no_access_token}

          nil ->
            fetch_api_key_token_from_vault_credentials(resolved_scope, organization_id, provider)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :provider_not_implemented} ->
        fetch_api_key_token_from_vault_credentials(resolved_scope, organization_id, provider)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_api_key_token_with_ref(resolved_scope, organization_id, provider, credential_ref) do
    with {:ok, normalized_provider} <-
           ProviderCatalog.resolve_provider_id_for_type(provider, :api_key),
         {:ok, api_credential_id} <- CredentialRef.id(credential_ref),
         {:ok, credential_result} <-
           AccountExternalAuth.resolve_credential_for_use(
             resolved_scope,
             organization_id,
             normalized_provider,
             api_credential_id: api_credential_id
           ) do
      {:ok,
       %{
         auth_method: :api_key,
         provider: normalized_provider,
         api_key: credential_result.api_key,
         api_credential_id: credential_result.api_credential_id
       }}
    end
  end

  defp fetch_api_key_token_from_vault_credentials(resolved_scope, organization_id, provider) do
    with {:ok, credential_result} <-
           AccountExternalAuth.resolve_credential_for_use(
             resolved_scope,
             organization_id,
             provider
           ) do
      {:ok,
       %{
         auth_method: :api_key,
         provider: provider,
         api_key: credential_result.api_key,
         api_credential_id: credential_result.api_credential_id
       }}
    end
  end

  defp provider_module_for_network_domains(provider) do
    case provider_module(provider) do
      {:ok, provider_mod} ->
        {:ok, provider_mod}

      {:error, _reason} ->
        ProviderCatalog.api_key_provider_module(provider)
    end
  end

  defp resolve_provider_for_execution(provider) when is_binary(provider) do
    case ProviderCatalog.resolve_provider_id_for_type(provider, :oauth) do
      {:ok, normalized_provider} ->
        {:ok, :oauth, normalized_provider}

      {:error, _reason} ->
        case ProviderCatalog.resolve_provider_id_for_type(provider, :api_key) do
          {:ok, normalized_provider} -> {:ok, :api_key, normalized_provider}
          {:error, _reason} -> {:error, :invalid_provider}
        end
    end
  end

  defp ensure_ref_provider_matches_requested(requested_provider, ref_provider) do
    oauth_match? =
      match?(
        {:ok, ^ref_provider},
        ProviderCatalog.resolve_provider_id_for_type(requested_provider, :oauth)
      )

    api_key_match? =
      match?(
        {:ok, ^ref_provider},
        ProviderCatalog.resolve_provider_id_for_type(requested_provider, :api_key)
      )

    if oauth_match? or api_key_match? do
      :ok
    else
      {:error, :credential_ref_provider_mismatch}
    end
  end
end
