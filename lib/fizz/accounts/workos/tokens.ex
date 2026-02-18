defmodule Fizz.Accounts.WorkOS.Tokens do
  @moduledoc """
  Scope-aware WorkOS token helpers for widgets and Pipes providers.
  """

  alias Fizz.Accounts.{Scope, User, WorkOS}
  alias Fizz.Accounts.WorkOS.Directory

  @doc """
  Generates a WorkOS widget token for the given organization.
  """
  @spec generate_widget_token(Scope.t() | nil, String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  def generate_widget_token(scope, organization_id, scopes \\ [])

  def generate_widget_token(
        %Scope{user: %User{workos_user_id: workos_user_id} = user},
        organization_id,
        scopes
      )
      when is_binary(workos_user_id) and is_binary(organization_id) and is_list(scopes) do
    if Directory.user_has_organization?(user, organization_id) do
      WorkOS.generate_widget_token(%{
        organization_id: organization_id,
        user_id: workos_user_id,
        scopes: scopes
      })
    else
      {:error, :forbidden}
    end
  end

  def generate_widget_token(%Scope{}, _organization_id, _scopes),
    do: {:error, :missing_workos_user_id}

  def generate_widget_token(_scope, _organization_id, _scopes),
    do: {:error, :unauthenticated}

  @doc """
  Fetches a Pipes provider access token for the current scope user.
  """
  @spec get_pipes_access_token(Scope.t() | nil, String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def get_pipes_access_token(
        %Scope{user: %User{workos_user_id: workos_user_id} = user},
        provider,
        organization_id
      )
      when is_binary(workos_user_id) and is_binary(provider) do
    if is_nil(organization_id) or Directory.user_has_organization?(user, organization_id) do
      WorkOS.get_pipes_access_token(provider, workos_user_id, organization_id)
    else
      {:error, :forbidden}
    end
  end

  def get_pipes_access_token(%Scope{}, _provider, _organization_id),
    do: {:error, :missing_workos_user_id}

  def get_pipes_access_token(_scope, _provider, _organization_id), do: {:error, :unauthenticated}
end
