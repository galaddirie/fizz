defmodule Fizz.Accounts.WorkOS.Organizations do
  @moduledoc """
  CRUD operations for WorkOS organizations.
  """

  require Logger

  import Fizz.Accounts.WorkOS.Helpers
  import Fizz.Accounts.WorkOS.Http

  @doc """
  Creates a WorkOS organization with the given name.
  """
  @spec create_organization(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_organization(name, opts \\ []) when is_binary(name) do
    body =
      compact_map(%{
        name: name,
        allow_profiles_outside_organization: Keyword.get(opts, :allow_profiles_outside_organization, true)
      })

    case api_request(:post, "/organizations", json: body) do
      {:ok, organization} ->
        {:ok, normalize_organization(organization)}

      {:error, error} ->
        log_error("create organization", error)
        {:error, normalize_error(error)}
    end
  end

  @doc """
  Fetches a WorkOS organization by ID.
  """
  @spec get_organization(String.t()) :: {:ok, map()} | {:error, term()}
  def get_organization(org_id) when is_binary(org_id) do
    case api_request(:get, "/organizations/#{org_id}", []) do
      {:ok, organization} ->
        {:ok, normalize_organization(organization)}

      {:error, error} ->
        log_error("get organization", error)
        {:error, normalize_error(error)}
    end
  end

  @doc """
  Updates a WorkOS organization.
  """
  @spec update_organization(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_organization(org_id, attrs) when is_binary(org_id) and is_map(attrs) do
    body = compact_map(attrs)

    case api_request(:put, "/organizations/#{org_id}", json: body) do
      {:ok, organization} ->
        {:ok, normalize_organization(organization)}

      {:error, error} ->
        log_error("update organization", error)
        {:error, normalize_error(error)}
    end
  end

  defp normalize_organization(organization) do
    %{
      id: read_value(organization, [:id, "id"]),
      name: read_value(organization, [:name, "name"])
    }
  end
end
