defmodule Fizz.Integrations do
  @moduledoc """
  Context for managing external integration connections (GitHub, GitLab, etc.).

  Tokens are never stored locally — they are always fetched live from WorkOS Pipes.
  The `integration_connections` table tracks connection status and metadata only.
  """

  alias Fizz.Accounts
  alias Fizz.Accounts.Scope
  alias Fizz.Integrations.IntegrationConnection
  alias Fizz.Repo

  import Ecto.Query

  require Logger

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
    with {:ok, provider_mod} <- provider_module(provider),
         {:ok, resolve_workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         org_id = resolve_workspace_scope.organization_id,
         {:ok, token_result} <- provider_mod.fetch_token(resolve_workspace_scope, org_id) do
      _ = touch_token_fetch(resolve_workspace_scope, workspace_id, provider)
      {:ok, token_result}
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

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp resolve_workspace_scope(scope, workspace_id) do
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
end
