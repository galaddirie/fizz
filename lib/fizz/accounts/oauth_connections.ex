defmodule Fizz.Accounts.OauthConnections do
  @moduledoc """
  Organization-scoped OAuth connection index operations.
  """

  import Ecto.Query

  alias Fizz.Accounts
  alias Fizz.Accounts.{OauthConnection, Scope}
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

  defp resolve_oauth_provider(_provider), do: {:error, :invalid_provider}
end
