defmodule Fizz.Integrations do
  @moduledoc """
  Context for managing external integration connections (GitHub, GitLab, etc.).

  Tokens are never stored locally — they are always fetched live from WorkOS Pipes.
  The `integration_connections` table tracks connection status and metadata only.
  """

  alias Fizz.Accounts
  alias Fizz.Accounts.Scope
  alias Fizz.Accounts.WorkOS

  alias Fizz.Integrations.{
    CredentialProviderCatalog,
    IntegrationConnection,
    IntegrationCredential,
    Vault
  }

  alias Fizz.Repo

  import Ecto.Query

  @providers %{
    "github" => Fizz.Integrations.Providers.GitHub
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns the provider module for the given provider ID, or error.
  """
  @spec provider_module(String.t()) :: {:ok, module()} | {:error, :unknown_provider}
  def provider_module(provider) when is_binary(provider) do
    case Map.fetch(@providers, provider) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, :unknown_provider}
    end
  end

  @doc """
  Returns the local DB record for a user's connection to a provider in a workspace.
  """
  @spec get_connection(Scope.t(), String.t(), String.t()) ::
          {:ok, IntegrationConnection.t()} | {:error, term()}
  def get_connection(%Scope{} = scope, workspace_id, provider) do
    with {:ok, resolve_workspace_scope} <- resolve_workspace_scope(scope, workspace_id) do
      query =
        from ic in IntegrationConnection,
          where:
            ic.workspace_id == ^workspace_id and
              ic.user_id == ^resolve_workspace_scope.user.id and
              ic.provider == ^provider

      case Repo.one(query) do
        nil -> {:error, :connection_not_found}
        connection -> {:ok, connection}
      end
    end
  end

  @doc """
  Checks the live connection status with the provider and upserts the local DB record.
  """
  @spec check_and_sync_connection(Scope.t(), String.t(), String.t()) ::
          {:ok, IntegrationConnection.t()} | {:error, term()}
  def check_and_sync_connection(%Scope{} = scope, workspace_id, provider) do
    with {:ok, provider_mod} <- provider_module(provider),
         {:ok, resolve_workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         org_id = resolve_workspace_scope.organization_id,
         {:ok, status} <- provider_mod.check_connection(resolve_workspace_scope, org_id) do
      upsert_connection(resolve_workspace_scope, workspace_id, provider, status)
    end
  end

  @doc """
  Fetches a live access token for use inside a sprite. Updates last_token_fetch_at.
  """
  @spec fetch_token_for_sprite(Scope.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def fetch_token_for_sprite(%Scope{} = scope, workspace_id, provider) do
    with {:ok, auth} <- resolve_auth_for_execution(scope, workspace_id, provider) do
      case auth.auth_method do
        :oauth ->
          _ = touch_token_fetch(auth.scope, workspace_id, provider)
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
  Resolves integration auth for execution-time use.
  """
  @spec resolve_auth_for_execution(Scope.t(), String.t(), String.t()) ::
          {:ok, %{auth_method: :oauth, token_result: map(), scope: Scope.t()}}
          | {:ok, %{auth_method: :api_key, api_key: String.t(), credential_id: String.t()}}
          | {:error, term()}
  def resolve_auth_for_execution(%Scope{} = scope, workspace_id, provider) do
    with {:ok, resolved_scope} <- resolve_workspace_scope(scope, workspace_id) do
      case fetch_connection_record(resolved_scope, workspace_id, provider) do
        %IntegrationConnection{auth_method: :api_key, credential_id: credential_id}
        when is_binary(credential_id) ->
          with {:ok, credential_result} <-
                 resolve_credential_for_use(resolved_scope, workspace_id, provider,
                   credential_id: credential_id
                 ) do
            {:ok,
             %{
               auth_method: :api_key,
               api_key: credential_result.api_key,
               credential_id: credential_result.credential_id
             }}
          end

        _connection ->
          with {:ok, provider_mod} <- provider_module(provider),
               org_id = resolved_scope.organization_id,
               {:ok, token_result} <- provider_mod.fetch_token(resolved_scope, org_id) do
            {:ok, %{auth_method: :oauth, token_result: token_result, scope: resolved_scope}}
          end
      end
    end
  end

  @doc """
  Binds a workspace/provider integration to an API credential owned by the caller.
  """
  @spec bind_api_key_credential(Scope.t(), String.t(), String.t(), String.t()) ::
          {:ok, IntegrationConnection.t()} | {:error, term()}
  def bind_api_key_credential(%Scope{} = scope, workspace_id, provider, credential_id)
      when is_binary(workspace_id) and is_binary(provider) and is_binary(credential_id) do
    with {:ok, resolved_scope} <- resolve_workspace_scope(scope, workspace_id),
         {:ok, credential} <-
           get_credential(resolved_scope, resolved_scope.organization_id, credential_id),
         true <- credential.provider == provider do
      now = DateTime.utc_now()

      attrs = %{
        workspace_id: workspace_id,
        user_id: resolved_scope.user.id,
        provider: provider,
        auth_method: :api_key,
        credential_id: credential.id,
        status: :active,
        scopes: [],
        missing_scopes: [],
        provider_metadata: %{},
        last_error: nil,
        disconnected_at: nil
      }

      %IntegrationConnection{}
      |> IntegrationConnection.changeset(attrs)
      |> Repo.insert(
        conflict_target: [:workspace_id, :user_id, :provider],
        on_conflict:
          {:replace,
           [
             :auth_method,
             :credential_id,
             :status,
             :scopes,
             :missing_scopes,
             :provider_metadata,
             :last_error,
             :disconnected_at,
             :updated_at
           ]},
        returning: true
      )
      |> case do
        {:ok, connection} ->
          _ =
            maybe_emit_credential_audit_event(
              resolved_scope,
              "integration.credential_bound",
              credential,
              %{provider: provider, connected_at: DateTime.to_iso8601(now)}
            )

          {:ok, connection}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :credential_provider_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists repos from the provider.
  """
  @spec list_repos(Scope.t(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_repos(%Scope{} = scope, workspace_id, provider, opts \\ []) do
    with {:ok, provider_mod} <- provider_module(provider),
         {:ok, resolve_workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         org_id = resolve_workspace_scope.organization_id do
      opts = Keyword.put(opts, :organization_id, org_id)
      provider_mod.list_repos(resolve_workspace_scope, opts)
    end
  end

  @doc """
  Creates a pull request via the provider.
  """
  @spec create_pull_request(Scope.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def create_pull_request(%Scope{} = scope, workspace_id, provider, params) do
    with {:ok, provider_mod} <- provider_module(provider),
         {:ok, resolve_workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         org_id = resolve_workspace_scope.organization_id do
      params = Map.put(params, "organization_id", org_id)
      provider_mod.create_pull_request(resolve_workspace_scope, params)
    end
  end

  @doc """
  Returns the network domains required for a provider.
  """
  @spec network_domains_for_provider(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def network_domains_for_provider(provider) do
    with {:ok, provider_mod} <- provider_module(provider) do
      {:ok, provider_mod.network_domains()}
    end
  end

  @doc """
  Lists organization-scoped API credentials owned by the current user.
  """
  @spec list_credentials(Scope.t(), String.t()) ::
          {:ok, [IntegrationCredential.t()]} | {:error, term()}
  def list_credentials(%Scope{} = scope, organization_id) do
    with {:ok, resolved_scope} <- Accounts.build_scope(scope, organization_id) do
      query =
        from credential in IntegrationCredential,
          where:
            credential.workos_organization_id == ^organization_id and
              credential.user_id == ^resolved_scope.user.id,
          order_by: [asc: credential.provider_label, asc: credential.inserted_at]

      {:ok, Repo.all(query)}
    end
  end

  @doc """
  Creates an organization-scoped API credential and stores the secret in WorkOS Vault.
  """
  @spec create_credential(Scope.t(), String.t(), map()) ::
          {:ok, IntegrationCredential.t()} | {:error, term()}
  def create_credential(%Scope{} = scope, organization_id, attrs)
      when is_binary(organization_id) and is_map(attrs) do
    with {:ok, resolved_scope} <- Accounts.build_scope(scope, organization_id),
         {:ok, normalized_attrs} <- normalize_credential_attrs(attrs),
         {:ok, vault_name} <-
           build_vault_object_name(organization_id, resolved_scope.user.id, normalized_attrs),
         {:ok, vault_response} <-
           Vault.create_object(resolved_scope, organization_id, %{
             name: vault_name,
             value: normalized_attrs.secret_value
           }),
         {:ok, vault_object_id} <- extract_vault_object_id(vault_response) do
      credential_attrs =
        normalized_attrs
        |> Map.take([:provider, :provider_label, :provider_custom_name])
        |> Map.put(:user_id, resolved_scope.user.id)
        |> Map.put(:workos_organization_id, organization_id)
        |> Map.put(:vault_object_id, vault_object_id)
        |> Map.put(:vault_object_name, vault_name)
        |> Map.put(:vault_version, extract_vault_version(vault_response))

      case %IntegrationCredential{}
           |> IntegrationCredential.changeset(credential_attrs)
           |> Repo.insert() do
        {:ok, credential} ->
          _ =
            maybe_emit_credential_audit_event(
              resolved_scope,
              "integration.credential_created",
              credential,
              %{provider: credential.provider}
            )

          {:ok, credential}

        {:error, changeset} ->
          _ = Vault.delete_object(resolved_scope, organization_id, vault_object_id)
          {:error, changeset}
      end
    end
  end

  @doc """
  Rotates the secret for an existing credential.
  """
  @spec rotate_credential(Scope.t(), String.t(), String.t(), map()) ::
          {:ok, IntegrationCredential.t()} | {:error, term()}
  def rotate_credential(%Scope{} = scope, organization_id, credential_id, attrs)
      when is_binary(organization_id) and is_binary(credential_id) and is_map(attrs) do
    with {:ok, resolved_scope} <- Accounts.build_scope(scope, organization_id),
         {:ok, credential} <- get_credential(resolved_scope, organization_id, credential_id),
         {:ok, secret_value} <- secret_value_from_attrs(attrs),
         {:ok, vault_response} <-
           Vault.update_object(resolved_scope, organization_id, credential.vault_object_id, %{
             value: secret_value,
             version_check: credential.vault_version
           }) do
      update_attrs = %{
        vault_version: extract_vault_version(vault_response) || credential.vault_version,
        provider_label:
          normalize_optional_string(attrs[:provider_label] || attrs["provider_label"]) ||
            credential.provider_label,
        provider_custom_name:
          normalize_optional_string(attrs[:provider_custom_name] || attrs["provider_custom_name"]) ||
            credential.provider_custom_name
      }

      case credential |> IntegrationCredential.changeset(update_attrs) |> Repo.update() do
        {:ok, updated_credential} ->
          _ =
            maybe_emit_credential_audit_event(
              resolved_scope,
              "integration.credential_rotated",
              updated_credential,
              %{provider: updated_credential.provider}
            )

          {:ok, updated_credential}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Deletes an organization-scoped credential and its backing Vault object.
  """
  @spec delete_credential(Scope.t(), String.t(), String.t()) ::
          {:ok, IntegrationCredential.t()} | {:error, term()}
  def delete_credential(%Scope{} = scope, organization_id, credential_id)
      when is_binary(organization_id) and is_binary(credential_id) do
    with {:ok, resolved_scope} <- Accounts.build_scope(scope, organization_id),
         {:ok, credential} <- get_credential(resolved_scope, organization_id, credential_id),
         :ok <-
           Vault.delete_object(resolved_scope, organization_id, credential.vault_object_id, %{
             version_check: credential.vault_version
           }),
         {:ok, deleted_credential} <- Repo.delete(credential) do
      _ =
        maybe_emit_credential_audit_event(
          resolved_scope,
          "integration.credential_deleted",
          deleted_credential,
          %{provider: deleted_credential.provider}
        )

      {:ok, deleted_credential}
    end
  end

  @doc """
  Resolves a credential for execution-time use, returning plaintext only on the server.
  """
  @spec resolve_credential_for_use(Scope.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_credential_for_use(%Scope{} = scope, workspace_id, provider, opts \\ [])
      when is_binary(workspace_id) and is_binary(provider) and is_list(opts) do
    credential_id = Keyword.get(opts, :credential_id)

    with {:ok, resolved_scope} <- resolve_workspace_scope(scope, workspace_id),
         {:ok, credential} <-
           fetch_credential_for_use(resolved_scope, provider, credential_id),
         {:ok, vault_object} <-
           Vault.read_object(
             resolved_scope,
             resolved_scope.organization_id,
             credential.vault_object_id
           ),
         {:ok, secret_value} <- extract_vault_value(vault_object) do
      _ = touch_credential_use(credential.id)

      {:ok,
       %{
         credential_id: credential.id,
         provider: credential.provider,
         provider_label: credential.provider_label,
         provider_custom_name: credential.provider_custom_name,
         api_key: secret_value
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @doc """
  Resolves a workspace-scoped caller for integration operations.
  """
  @spec resolve_workspace_scope(Scope.t(), String.t()) :: {:ok, Scope.t()} | {:error, term()}
  def resolve_workspace_scope(scope, workspace_id) do
    Accounts.build_scope_for_workspace(scope, workspace_id)
  end

  defp upsert_connection(resolve_workspace_scope, workspace_id, provider, status) do
    now = DateTime.utc_now()
    user_id = resolve_workspace_scope.user.id

    {db_status, error, disconnected_at} =
      cond do
        status.active ->
          {:active, nil, nil}

        status.error == :needs_reauthorization ->
          {:needs_reauthorization, "needs_reauthorization", nil}

        status.error != nil ->
          {:error, inspect(status.error), now}

        true ->
          {:inactive, nil, now}
      end

    attrs = %{
      workspace_id: workspace_id,
      user_id: user_id,
      provider: provider,
      auth_method: :oauth,
      credential_id: nil,
      status: db_status,
      scopes: status.scopes,
      missing_scopes: status.missing_scopes,
      provider_metadata: status.provider_metadata,
      last_error: error,
      disconnected_at: disconnected_at
    }

    %IntegrationConnection{}
    |> IntegrationConnection.changeset(attrs)
    |> Repo.insert(
      conflict_target: [:workspace_id, :user_id, :provider],
      on_conflict:
        {:replace,
         [
           :auth_method,
           :credential_id,
           :status,
           :scopes,
           :missing_scopes,
           :provider_metadata,
           :last_error,
           :disconnected_at,
           :updated_at
         ]},
      returning: true
    )
  end

  defp touch_token_fetch(resolve_workspace_scope, workspace_id, provider) do
    now = DateTime.utc_now()
    user_id = resolve_workspace_scope.user.id

    from(ic in IntegrationConnection,
      where:
        ic.workspace_id == ^workspace_id and
          ic.user_id == ^user_id and
          ic.provider == ^provider
    )
    |> Repo.update_all(set: [last_token_fetch_at: now])
  end

  defp touch_credential_use(credential_id) do
    from(credential in IntegrationCredential, where: credential.id == ^credential_id)
    |> Repo.update_all(set: [last_used_at: DateTime.utc_now()])
  end

  defp get_credential(%Scope{} = resolved_scope, organization_id, credential_id) do
    query =
      from credential in IntegrationCredential,
        where:
          credential.id == ^credential_id and
            credential.workos_organization_id == ^organization_id and
            credential.user_id == ^resolved_scope.user.id

    case Repo.one(query) do
      %IntegrationCredential{} = credential -> {:ok, credential}
      nil -> {:error, :credential_not_found}
    end
  end

  defp fetch_connection_record(%Scope{} = resolved_scope, workspace_id, provider) do
    query =
      from connection in IntegrationConnection,
        where:
          connection.workspace_id == ^workspace_id and
            connection.user_id == ^resolved_scope.user.id and
            connection.provider == ^provider,
        limit: 1

    Repo.one(query)
  end

  defp fetch_credential_for_use(%Scope{} = resolved_scope, provider, credential_id)
       when is_binary(credential_id) do
    with {:ok, credential} <-
           get_credential(resolved_scope, resolved_scope.organization_id, credential_id),
         true <- credential.provider == provider do
      {:ok, credential}
    else
      false -> {:error, :credential_provider_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_credential_for_use(%Scope{} = resolved_scope, provider, _credential_id) do
    query =
      from credential in IntegrationCredential,
        where:
          credential.workos_organization_id == ^resolved_scope.organization_id and
            credential.user_id == ^resolved_scope.user.id and
            credential.provider == ^provider,
        limit: 1

    case Repo.one(query) do
      %IntegrationCredential{} = credential -> {:ok, credential}
      nil -> {:error, :credential_not_found}
    end
  end

  defp normalize_credential_attrs(attrs) when is_map(attrs) do
    provider = attrs[:provider] || attrs["provider"]
    provider_label = attrs[:provider_label] || attrs["provider_label"] || provider
    provider_custom_name = attrs[:provider_custom_name] || attrs["provider_custom_name"]

    with {:ok, normalized_provider} <- normalize_provider(provider),
         {:ok, secret_value} <- secret_value_from_attrs(attrs),
         :ok <- validate_provider_custom_name(normalized_provider, provider_custom_name),
         :ok <- validate_provider_label(provider_label) do
      {:ok,
       %{
         provider: normalized_provider,
         provider_label: String.trim(provider_label),
         provider_custom_name: normalize_optional_string(provider_custom_name),
         secret_value: secret_value
       }}
    end
  end

  defp normalize_provider(provider) when is_binary(provider) do
    normalized =
      provider
      |> String.trim()
      |> String.downcase()

    if byte_size(normalized) > 1 and CredentialProviderCatalog.provider_supported?(normalized) do
      {:ok, normalized}
    else
      {:error, :invalid_provider}
    end
  end

  defp normalize_provider(_provider), do: {:error, :invalid_provider}

  defp secret_value_from_attrs(attrs) when is_map(attrs) do
    value = attrs[:secret] || attrs["secret"] || attrs[:value] || attrs["value"]

    case value do
      secret when is_binary(secret) ->
        trimmed_secret = String.trim(secret)

        if byte_size(trimmed_secret) > 0 do
          {:ok, trimmed_secret}
        else
          {:error, :missing_secret_value}
        end

      _ ->
        {:error, :missing_secret_value}
    end
  end

  defp validate_provider_label(provider_label) when is_binary(provider_label) do
    if byte_size(String.trim(provider_label)) > 1,
      do: :ok,
      else: {:error, :invalid_provider_label}
  end

  defp validate_provider_label(_provider_label), do: {:error, :invalid_provider_label}

  defp validate_provider_custom_name("custom", provider_custom_name) do
    if is_binary(provider_custom_name) and byte_size(String.trim(provider_custom_name)) > 1 do
      :ok
    else
      {:error, :missing_custom_provider_name}
    end
  end

  defp validate_provider_custom_name(_provider, _provider_custom_name), do: :ok

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_value), do: nil

  defp extract_vault_object_id(vault_response) when is_map(vault_response) do
    case vault_response["id"] || vault_response[:id] do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :invalid_vault_object_response}
    end
  end

  defp extract_vault_version(vault_response) when is_map(vault_response) do
    metadata = vault_response["metadata"] || vault_response[:metadata]

    case metadata do
      %{} -> metadata["version_id"] || metadata[:version_id]
      _ -> nil
    end
  end

  defp extract_vault_value(vault_response) when is_map(vault_response) do
    case vault_response["value"] || vault_response[:value] do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, :vault_secret_not_found}
    end
  end

  defp build_vault_object_name(organization_id, user_id, credential_attrs) do
    suffix = credential_attrs.provider_custom_name || credential_attrs.provider_label

    {:ok,
     Vault.object_name(
       organization_id,
       to_string(user_id),
       credential_attrs.provider,
       suffix
     )}
  end

  defp maybe_emit_credential_audit_event(
         %Scope{organization_id: organization_id, user: user},
         action,
         %IntegrationCredential{} = credential,
         context
       )
       when is_binary(organization_id) do
    targets = [
      %{type: "organization", id: organization_id},
      %{type: "user", id: to_string(credential.user_id)},
      %{type: "integration_credential", id: to_string(credential.id)}
    ]

    case WorkOS.create_audit_event(organization_id, user, action, targets, context) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp maybe_emit_credential_audit_event(_scope, _action, _credential, _context), do: :ok
end
