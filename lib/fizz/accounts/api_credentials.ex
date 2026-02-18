defmodule Fizz.Accounts.ApiCredentials do
  @moduledoc """
  Organization-scoped API credential operations backed by WorkOS Vault.
  """

  import Ecto.Query

  alias Fizz.Accounts
  alias Fizz.Accounts.{ApiCredential, Scope, WorkOS}
  alias Fizz.Accounts.WorkOS.Vault
  alias Fizz.Integrations.ProviderCatalog
  alias Fizz.Repo

  @doc """
  Lists organization-scoped API credentials owned by the current user.
  """
  @spec list_credentials(Scope.t(), String.t()) ::
          {:ok, [ApiCredential.t()]} | {:error, term()}
  def list_credentials(%Scope{} = scope, organization_id) when is_binary(organization_id) do
    with {:ok, resolved_scope} <- resolve_organization_scope(scope, organization_id) do
      query =
        from credential in ApiCredential,
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
          {:ok, ApiCredential.t()} | {:error, term()}
  def create_credential(%Scope{} = scope, organization_id, attrs)
      when is_binary(organization_id) and is_map(attrs) do
    with {:ok, resolved_scope} <- resolve_organization_scope(scope, organization_id),
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

      case %ApiCredential{}
           |> ApiCredential.changeset(credential_attrs)
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
          {:ok, ApiCredential.t()} | {:error, term()}
  def rotate_credential(%Scope{} = scope, organization_id, credential_id, attrs)
      when is_binary(organization_id) and is_binary(credential_id) and is_map(attrs) do
    with {:ok, resolved_scope} <- resolve_organization_scope(scope, organization_id),
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

      case credential |> ApiCredential.changeset(update_attrs) |> Repo.update() do
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
          {:ok, ApiCredential.t()} | {:error, term()}
  def delete_credential(%Scope{} = scope, organization_id, credential_id)
      when is_binary(organization_id) and is_binary(credential_id) do
    with {:ok, resolved_scope} <- resolve_organization_scope(scope, organization_id),
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
  Resolves a credential for server-side execution-time use.
  """
  @spec resolve_credential_for_use(Scope.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_credential_for_use(%Scope{} = scope, organization_id, provider, opts \\ [])
      when is_binary(organization_id) and is_binary(provider) and is_list(opts) do
    api_credential_id = Keyword.get(opts, :api_credential_id) || Keyword.get(opts, :credential_id)

    with {:ok, resolved_scope} <- resolve_organization_scope(scope, organization_id),
         {:ok, normalized_provider} <- resolve_api_key_provider(provider),
         {:ok, api_credential} <-
           fetch_credential_for_use(
             resolved_scope,
             organization_id,
             normalized_provider,
             api_credential_id
           ),
         {:ok, vault_object} <-
           Vault.read_object(
             resolved_scope,
             organization_id,
             api_credential.vault_object_id
           ),
         {:ok, secret_value} <- extract_vault_value(vault_object) do
      _ = touch_credential_use(api_credential.id)

      {:ok,
       %{
         api_credential_id: api_credential.id,
         credential_id: api_credential.id,
         provider: api_credential.provider,
         provider_label: api_credential.provider_label,
         provider_custom_name: api_credential.provider_custom_name,
         api_key: secret_value
       }}
    end
  end

  @doc """
  Returns a credential metadata record for the current scope in an organization.
  """
  @spec get_credential(Scope.t(), String.t(), String.t()) ::
          {:ok, ApiCredential.t()} | {:error, :credential_not_found}
  def get_credential(%Scope{} = resolved_scope, organization_id, api_credential_id)
      when is_binary(organization_id) and is_binary(api_credential_id) do
    query =
      from api_credential in ApiCredential,
        where:
          api_credential.id == ^api_credential_id and
            api_credential.workos_organization_id == ^organization_id and
            api_credential.user_id == ^resolved_scope.user.id

    case Repo.one(query) do
      %ApiCredential{} = api_credential -> {:ok, api_credential}
      nil -> {:error, :credential_not_found}
    end
  end

  defp resolve_organization_scope(
         %Scope{organization_id: organization_id} = scope,
         organization_id
       )
       when is_binary(organization_id),
       do: {:ok, scope}

  defp resolve_organization_scope(%Scope{} = scope, organization_id)
       when is_binary(organization_id),
       do: Accounts.build_scope(scope, organization_id)

  defp touch_credential_use(api_credential_id) do
    from(api_credential in ApiCredential, where: api_credential.id == ^api_credential_id)
    |> Repo.update_all(set: [last_used_at: DateTime.utc_now()])
  end

  defp fetch_credential_for_use(
         %Scope{} = resolved_scope,
         organization_id,
         provider,
         api_credential_id
       )
       when is_binary(api_credential_id) do
    with {:ok, api_credential} <-
           get_credential(resolved_scope, organization_id, api_credential_id),
         true <- api_credential.provider == provider do
      {:ok, api_credential}
    else
      false -> {:error, :credential_provider_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_credential_for_use(
         %Scope{} = resolved_scope,
         organization_id,
         provider,
         _api_credential_id
       ) do
    query =
      from api_credential in ApiCredential,
        where:
          api_credential.workos_organization_id == ^organization_id and
            api_credential.user_id == ^resolved_scope.user.id and
            api_credential.provider == ^provider,
        limit: 1

    case Repo.one(query) do
      %ApiCredential{} = api_credential -> {:ok, api_credential}
      nil -> {:error, :credential_not_found}
    end
  end

  defp normalize_credential_attrs(attrs) when is_map(attrs) do
    provider = attrs[:provider] || attrs["provider"]
    provider_label = attrs[:provider_label] || attrs["provider_label"] || provider
    provider_custom_name = attrs[:provider_custom_name] || attrs["provider_custom_name"]

    with {:ok, normalized_provider} <- resolve_api_key_provider(provider),
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

  defp resolve_api_key_provider(provider) when is_binary(provider) do
    ProviderCatalog.resolve_provider_id_for_type(provider, :api_key)
  end

  defp resolve_api_key_provider(_provider), do: {:error, :invalid_provider}

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

  defp validate_provider_custom_name(provider, provider_custom_name) when is_binary(provider) do
    case ProviderCatalog.provider_for_type(provider, :api_key) do
      {:ok, %{custom: true}} ->
        if is_binary(provider_custom_name) and byte_size(String.trim(provider_custom_name)) > 1 do
          :ok
        else
          {:error, :missing_custom_provider_name}
        end

      _ ->
        :ok
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
     Vault.object_name(organization_id, to_string(user_id), credential_attrs.provider, suffix)}
  end

  defp maybe_emit_credential_audit_event(
         %Scope{organization_id: organization_id, user: user},
         action,
         %ApiCredential{} = credential,
         context
       )
       when is_binary(organization_id) do
    targets = [
      %{type: "organization", id: organization_id},
      %{type: "user", id: to_string(credential.user_id)},
      %{type: "api_credential", id: to_string(credential.id)}
    ]

    case WorkOS.create_audit_event(organization_id, user, action, targets, context) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp maybe_emit_credential_audit_event(_scope, _action, _credential, _context), do: :ok
end
