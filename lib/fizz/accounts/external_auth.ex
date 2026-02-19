defmodule Fizz.Accounts.ExternalAuth do
  @moduledoc """
  Accounts-owned integration auth primitives for organization-scoped OAuth
  connection indexing and API credential lifecycle operations.
  """

  import Ecto.Query

  alias Fizz.Accounts
  alias Fizz.Accounts.{ApiCredential, OauthConnection, Scope, User, WorkOS}
  alias Fizz.Accounts.WorkOS.Vault
  alias Fizz.Integrations.ProviderCatalog
  alias Fizz.Repo

  @doc """
  Returns the indexed auth connection for a user/provider in an organization.
  """
  @spec get_connection(Scope.t(), String.t(), String.t()) ::
          {:ok, OauthConnection.t()} | {:error, term()}
  def get_connection(%Scope{} = scope, organization_id, provider)
      when is_binary(organization_id) and is_binary(provider) do
    with {:ok, resolved_scope} <- resolve_organization_scope(scope, organization_id),
         {:ok, normalized_provider} <- resolve_oauth_provider(provider) do
      query =
        from connection in OauthConnection,
          where:
            connection.workos_organization_id == ^organization_id and
              connection.user_id == ^resolved_scope.user.id and
              connection.provider == ^normalized_provider,
          limit: 1

      case Repo.one(query) do
        %OauthConnection{} = connection -> {:ok, connection}
        nil -> {:error, :connection_not_found}
      end
    end
  end

  @doc """
  Upserts OAuth connection metadata for a provider in an organization.
  """
  @spec upsert_oauth_connection(Scope.t(), String.t(), String.t(), map()) ::
          {:ok, OauthConnection.t()} | {:error, term()}
  def upsert_oauth_connection(%Scope{} = scope, organization_id, provider, status)
      when is_binary(organization_id) and is_binary(provider) and is_map(status) do
    with {:ok, resolved_scope} <- resolve_organization_scope(scope, organization_id),
         {:ok, normalized_provider} <- resolve_oauth_provider(provider) do
      now = DateTime.utc_now()

      active? = status[:active] in [true, "true"]
      status_error = status[:error]

      {db_status, error, disconnected_at} =
        cond do
          active? ->
            {:active, nil, nil}

          status_error == :needs_reauthorization ->
            {:needs_reauthorization, "needs_reauthorization", nil}

          status_error != nil ->
            {:error, inspect(status_error), now}

          true ->
            {:inactive, nil, now}
        end

      attrs = %{
        workos_organization_id: organization_id,
        user_id: resolved_scope.user.id,
        provider: normalized_provider,
        status: db_status,
        scopes: status[:scopes] || [],
        missing_scopes: status[:missing_scopes] || [],
        provider_metadata: status[:provider_metadata] || %{},
        last_error: error,
        disconnected_at: disconnected_at
      }

      %OauthConnection{}
      |> OauthConnection.changeset(attrs)
      |> Repo.insert(
        conflict_target: [:workos_organization_id, :user_id, :provider],
        on_conflict:
          {:replace,
           [
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
  end

  @doc """
  Touches token fetch timestamp for an indexed provider connection.
  """
  @spec touch_connection_token_fetch(Scope.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def touch_connection_token_fetch(%Scope{} = scope, organization_id, provider)
      when is_binary(organization_id) and is_binary(provider) do
    with {:ok, resolved_scope} <- resolve_organization_scope(scope, organization_id),
         {:ok, normalized_provider} <- resolve_oauth_provider(provider) do
      now = DateTime.utc_now()

      from(connection in OauthConnection,
        where:
          connection.workos_organization_id == ^organization_id and
            connection.user_id == ^resolved_scope.user.id and
            connection.provider == ^normalized_provider
      )
      |> Repo.update_all(set: [last_token_fetch_at: now])

      :ok
    end
  end

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
  Lists non-sensitive auth options (API keys + OAuth connections) for an organization.

  This endpoint is intended for workflow editor credential selection and does not
  return any secret/token material.
  """
  @spec list_credential_options(Scope.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_credential_options(%Scope{} = scope, organization_id, opts \\ [])
      when is_binary(organization_id) and is_list(opts) do
    with {:ok, _resolved_scope} <- resolve_organization_scope(scope, organization_id) do
      provider_filter = normalize_provider_filter(opts)
      auth_types = normalize_auth_type_filter(opts)

      api_key_options =
        if :api_key in auth_types do
          list_api_key_credential_options(organization_id, provider_filter)
        else
          []
        end

      oauth_options =
        if :oauth in auth_types do
          list_oauth_connection_options(organization_id, provider_filter)
        else
          []
        end

      options =
        (api_key_options ++ oauth_options)
        |> Enum.sort_by(fn option ->
          {
            option["provider_label"],
            option["display_name"] || "",
            option["owner_display_name"] || "",
            option["created_at"]
          }
        end)

      {:ok, options}
    end
  end

  @doc """
  Resolves an OAuth connection metadata record for strict execution-time binding.
  """
  @spec resolve_connection_for_use(Scope.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_connection_for_use(scope, organization_id, provider, opts \\ [])
      when is_binary(organization_id) and is_binary(provider) and is_list(opts) do
    oauth_connection_id =
      Keyword.get(opts, :oauth_connection_id) || Keyword.get(opts, :connection_id)

    with {:ok, resolved_scope} <- resolve_organization_scope(scope, organization_id),
         {:ok, normalized_provider} <- resolve_oauth_provider(provider),
         {:ok, connection} <-
           fetch_connection_for_use(
             resolved_scope,
             organization_id,
             normalized_provider,
             oauth_connection_id
           ) do
      {:ok,
       %{
         oauth_connection_id: connection.id,
         connection_id: connection.id,
         provider: connection.provider,
         status: connection.status,
         scopes: connection.scopes || [],
         missing_scopes: connection.missing_scopes || [],
         provider_metadata: connection.provider_metadata || %{},
         user_id: connection.user_id
       }}
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
         {:ok, vault_name} <- build_vault_object_name(normalized_attrs),
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
  def resolve_credential_for_use(scope, organization_id, provider, opts \\ []) do
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

  defp resolve_organization_scope(
         %Scope{organization_id: organization_id} = scope,
         organization_id
       )
       when is_binary(organization_id),
       do: {:ok, scope}

  defp resolve_organization_scope(%Scope{} = scope, organization_id)
       when is_binary(organization_id),
       do: Accounts.build_scope(scope, organization_id)

  defp resolve_oauth_provider(provider) when is_binary(provider),
    do: ProviderCatalog.resolve_provider_id_for_type(provider, :oauth)

  defp get_credential(%Scope{} = resolved_scope, organization_id, api_credential_id)
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

  defp get_connection_by_id(%Scope{} = resolved_scope, organization_id, oauth_connection_id)
       when is_binary(organization_id) and is_binary(oauth_connection_id) do
    query =
      from oauth_connection in OauthConnection,
        where:
          oauth_connection.id == ^oauth_connection_id and
            oauth_connection.workos_organization_id == ^organization_id and
            oauth_connection.user_id == ^resolved_scope.user.id

    case Repo.one(query) do
      %OauthConnection{} = oauth_connection -> {:ok, oauth_connection}
      nil -> {:error, :connection_not_found}
    end
  end

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
        order_by: [desc: api_credential.inserted_at],
        limit: 1

    case Repo.one(query) do
      %ApiCredential{} = api_credential -> {:ok, api_credential}
      nil -> {:error, :credential_not_found}
    end
  end

  defp fetch_connection_for_use(
         %Scope{} = resolved_scope,
         organization_id,
         provider,
         oauth_connection_id
       )
       when is_binary(oauth_connection_id) do
    with {:ok, oauth_connection} <-
           get_connection_by_id(resolved_scope, organization_id, oauth_connection_id),
         true <- oauth_connection.provider == provider do
      if oauth_connection.status == :active do
        {:ok, oauth_connection}
      else
        {:error, :connection_inactive}
      end
    else
      false -> {:error, :connection_provider_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_connection_for_use(
         %Scope{} = _resolved_scope,
         _organization_id,
         _provider,
         _oauth_connection_id
       ) do
    {:error, :oauth_connection_id_required}
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

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_provider_filter(opts) do
    opts
    |> Keyword.get(:provider_filter, [])
    |> List.wrap()
    |> Enum.map(&normalize_provider_id/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_provider_id(provider_id) when is_binary(provider_id),
    do: provider_id |> String.trim() |> String.downcase()

  defp normalize_provider_id(_provider_id), do: ""

  defp normalize_auth_type_filter(opts) do
    opts
    |> Keyword.get(:auth_types, [:api_key, :oauth])
    |> List.wrap()
    |> Enum.reduce([], fn
      :api_key, acc -> [:api_key | acc]
      :oauth, acc -> [:oauth | acc]
      "api_key", acc -> [:api_key | acc]
      "oauth", acc -> [:oauth | acc]
      _, acc -> acc
    end)
    |> Enum.uniq()
  end

  defp list_api_key_credential_options(organization_id, provider_filter) do
    query =
      from credential in ApiCredential,
        join: user in User,
        on: user.id == credential.user_id,
        where: credential.workos_organization_id == ^organization_id,
        order_by: [
          asc: credential.provider,
          asc: credential.provider_label,
          asc: credential.inserted_at
        ],
        select: %{
          id: credential.id,
          provider: credential.provider,
          display_name: credential.provider_label,
          owner_user_id: credential.user_id,
          owner_email: user.email,
          status: "active",
          created_at: credential.inserted_at,
          last_used_at: credential.last_used_at
        }

    query
    |> Repo.all()
    |> Enum.filter(fn option ->
      provider_allowed?(provider_filter, option.provider)
    end)
    |> Enum.map(fn option ->
      %{
        "id" => option.id,
        "provider" => option.provider,
        "provider_label" => provider_display_name(option.provider),
        "auth_type" => "api_key",
        "display_name" => option.display_name,
        "owner_user_id" => option.owner_user_id,
        "owner_display_name" => owner_display_name(option.owner_email, option.owner_user_id),
        "status" => option.status,
        "created_at" => datetime_to_iso8601(option.created_at),
        "last_used_at" => datetime_to_iso8601(option.last_used_at)
      }
    end)
  end

  defp list_oauth_connection_options(organization_id, provider_filter) do
    query =
      from connection in OauthConnection,
        join: user in User,
        on: user.id == connection.user_id,
        where: connection.workos_organization_id == ^organization_id,
        order_by: [asc: connection.provider, asc: connection.inserted_at],
        select: %{
          id: connection.id,
          provider: connection.provider,
          provider_metadata: connection.provider_metadata,
          owner_user_id: connection.user_id,
          owner_email: user.email,
          status: connection.status,
          created_at: connection.inserted_at,
          last_used_at: connection.last_token_fetch_at
        }

    query
    |> Repo.all()
    |> Enum.filter(fn option ->
      provider_allowed?(provider_filter, option.provider)
    end)
    |> Enum.map(fn option ->
      display_name = oauth_display_name(option.provider, option.provider_metadata)

      %{
        "id" => option.id,
        "provider" => option.provider,
        "provider_label" => provider_display_name(option.provider),
        "auth_type" => "oauth",
        "display_name" => display_name,
        "owner_user_id" => option.owner_user_id,
        "owner_display_name" => owner_display_name(option.owner_email, option.owner_user_id),
        "status" => to_string(option.status),
        "created_at" => datetime_to_iso8601(option.created_at),
        "last_used_at" => datetime_to_iso8601(option.last_used_at)
      }
    end)
  end

  defp provider_allowed?(provider_filter, provider) do
    if is_struct(provider_filter, MapSet) and MapSet.size(provider_filter) > 0 do
      MapSet.member?(provider_filter, normalize_provider_id(provider))
    else
      true
    end
  end

  defp provider_display_name(provider_id) when is_binary(provider_id) do
    case ProviderCatalog.provider(provider_id) do
      {:ok, provider} -> provider.label
      {:error, :unknown_provider} -> provider_id
    end
  end

  defp owner_display_name(owner_email, owner_user_id) when is_binary(owner_email) do
    owner_email
    |> String.split("@")
    |> List.first()
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> owner_user_id
    end
  end

  defp owner_display_name(_owner_email, owner_user_id), do: owner_user_id

  defp oauth_display_name(provider, provider_metadata) when is_map(provider_metadata) do
    username =
      provider_metadata["username"] ||
        provider_metadata[:username] ||
        provider_metadata["name"] ||
        provider_metadata[:name]

    case username do
      value when is_binary(value) and value != "" -> value
      _ -> provider_display_name(provider)
    end
  end

  defp oauth_display_name(provider, _provider_metadata), do: provider_display_name(provider)

  defp datetime_to_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_to_iso8601(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp datetime_to_iso8601(_datetime), do: nil

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

  defp build_vault_object_name(credential_attrs) do
    display_name = credential_attrs.provider_custom_name || credential_attrs.provider_label
    {:ok, Vault.object_name(display_name)}
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
