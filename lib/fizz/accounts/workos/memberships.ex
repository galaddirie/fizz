defmodule Fizz.Accounts.WorkOS.Memberships do
  @moduledoc false

  require Logger

  import Fizz.Accounts.WorkOS.Helpers
  import Fizz.Accounts.WorkOS.Http

  alias Fizz.Accounts.User

  @doc """
  Returns whether WorkOS sync is enabled.
  """
  def enabled?, do: Application.get_env(:fizz, :workos_sync_enabled, false)

  @doc """
  Ensures a local user has a WorkOS user record.
  """
  @spec ensure_user(%User{}) :: {:ok, String.t()} | {:error, term()}
  def ensure_user(%User{workos_user_id: workos_user_id}) when is_binary(workos_user_id) do
    {:ok, workos_user_id}
  end

  def ensure_user(%User{} = user) do
    with {:ok, created_user} <-
           user_management_module().create_user(%{
             email: user.email,
             external_id: to_string(user.id),
             email_verified: not is_nil(user.confirmed_at)
           }) do
      {:ok, created_user.id}
    else
      {:error, error} ->
        log_error("create user", error)
        {:error, normalize_error(error)}
    end
  rescue
    error in RuntimeError ->
      Logger.error("WorkOS configuration error when creating user: #{Exception.message(error)}")
      {:error, :workos_not_configured}
  end

  @doc """
  Ensures a user has organization membership in WorkOS for the given organization.
  """
  @spec ensure_organization_membership(String.t(), %User{}, atom() | String.t() | nil) ::
          {:ok, %{user_id: String.t() | nil, membership_id: String.t() | nil}} | {:error, term()}
  def ensure_organization_membership(workos_organization_id, user, role \\ :member)

  def ensure_organization_membership(
        workos_organization_id,
        %User{} = user,
        role
      )
      when is_binary(workos_organization_id) do
    if enabled?() do
      with {:ok, workos_user_id} <- ensure_user(user),
           {:ok, membership_id} <-
             find_or_create_organization_membership(workos_user_id, workos_organization_id, role) do
        {:ok, %{user_id: workos_user_id, membership_id: membership_id}}
      end
    else
      {:ok, %{user_id: user.workos_user_id, membership_id: nil}}
    end
  end

  def ensure_organization_membership(_workos_organization_id, %User{} = user, _role) do
    if enabled?() do
      {:error, :missing_workos_organization_id}
    else
      {:ok, %{user_id: user.workos_user_id, membership_id: nil}}
    end
  end

  @doc """
  Creates a WorkOS organization membership.
  """
  @spec create_organization_membership(String.t(), String.t(), atom() | String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def create_organization_membership(workos_user_id, workos_organization_id, role \\ nil)
      when is_binary(workos_user_id) and is_binary(workos_organization_id) do
    body =
      compact_map(%{
        user_id: workos_user_id,
        organization_id: workos_organization_id,
        role_slug: role_slug_for(role)
      })

    case api_request(:post, "/user_management/organization_memberships", json: body) do
      {:ok, membership} ->
        {:ok, membership}

      {:error, error} ->
        log_error("create organization membership", error)
        {:error, normalize_error(error)}
    end
  end

  @doc """
  Lists organization memberships for a WorkOS user.
  """
  @spec list_user_organization_memberships(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_user_organization_memberships(workos_user_id) when is_binary(workos_user_id) do
    case list_organization_memberships(workos_user_id, nil) do
      {:ok, memberships} ->
        {:ok, Enum.filter(memberships, &membership_active?/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the active membership for a WorkOS user in a specific organization.
  """
  @spec get_user_organization_membership(String.t(), String.t()) ::
          {:ok, map()} | {:error, :forbidden | term()}
  def get_user_organization_membership(workos_user_id, organization_id)
      when is_binary(workos_user_id) and is_binary(organization_id) do
    case list_organization_memberships(workos_user_id, organization_id) do
      {:ok, memberships} ->
        case Enum.find(memberships, &membership_active?/1) do
          nil -> {:error, :forbidden}
          membership -> {:ok, membership}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns true when the WorkOS user has an active membership in the organization.
  """
  @spec user_has_organization_membership?(String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def user_has_organization_membership?(workos_user_id, organization_id)
      when is_binary(workos_user_id) and is_binary(organization_id) do
    case list_organization_memberships(workos_user_id, organization_id) do
      {:ok, memberships} ->
        {:ok, Enum.any?(memberships, &membership_active?/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_or_create_organization_membership(workos_user_id, workos_organization_id, role) do
    desired_role_slug = role_slug_for(role)

    with {:ok, memberships} <-
           list_organization_memberships(workos_user_id, workos_organization_id) do
      case select_active_membership(memberships) do
        nil ->
          with {:ok, created_membership} <-
                 create_organization_membership(
                   workos_user_id,
                   workos_organization_id,
                   desired_role_slug
                 ),
               {:ok, id} <- membership_id(created_membership) do
            {:ok, id}
          end

        membership ->
          with {:ok, id} <- membership_id(membership),
               :ok <- maybe_sync_membership_role(id, membership, desired_role_slug) do
            {:ok, id}
          end
      end
    end
  end

  defp maybe_sync_membership_role(_membership_id, _membership, nil), do: :ok

  defp maybe_sync_membership_role(membership_id, membership, desired_role_slug) do
    if membership_has_role_slug?(membership, desired_role_slug) do
      :ok
    else
      case update_organization_membership_role(membership_id, desired_role_slug) do
        {:ok, _updated_membership} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp update_organization_membership_role(membership_id, role_slug)
       when is_binary(membership_id) and is_binary(role_slug) do
    case api_request(
           :put,
           "/user_management/organization_memberships/#{membership_id}",
           json: %{role_slug: role_slug}
         ) do
      {:ok, membership} ->
        {:ok, membership}

      {:error, error} ->
        log_error("update organization membership", error)
        {:error, normalize_error(error)}
    end
  end

  defp list_organization_memberships(workos_user_id, workos_organization_id) do
    case api_request(:get, "/user_management/organization_memberships",
           query: %{
             user_id: workos_user_id,
             organization_id: workos_organization_id,
             limit: 10
           }
         ) do
      {:ok, response} ->
        {:ok, extract_membership_data(response)}

      {:error, error} ->
        log_error("list organization memberships", error)
        {:error, normalize_error(error)}
    end
  end

  # Bug fix: removed `|| List.first(memberships)` fallback that silently
  # returned inactive memberships. The caller handles nil by creating a
  # new membership.
  defp select_active_membership(memberships) when is_list(memberships) do
    Enum.find(memberships, &membership_active?/1)
  end

  defp select_active_membership(_memberships), do: nil

  defp membership_active?(membership) do
    case membership_status(membership) do
      "active" -> true
      "" -> true
      _ -> false
    end
  end

  defp membership_status(membership) do
    membership
    |> read_value([:status, "status"])
    |> to_string()
  end

  defp membership_has_role_slug?(membership, desired_role_slug)
       when is_binary(desired_role_slug) do
    membership
    |> membership_role_slugs()
    |> Enum.member?(desired_role_slug)
  end

  defp extract_membership_data(%{data: data}) when is_list(data), do: data
  defp extract_membership_data(%{"data" => data}) when is_list(data), do: data
  defp extract_membership_data(_), do: []

  defp membership_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp membership_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
  defp membership_id(_membership), do: {:error, :invalid_workos_membership}

  defp role_slug_for(nil), do: nil

  defp role_slug_for(role) when is_atom(role) do
    Map.get(role_slug_map(), role) || to_string(role)
  end

  defp role_slug_for(role) when is_binary(role) do
    if String.trim(role) == "" do
      nil
    else
      role
    end
  end

  defp role_slug_for(_role), do: nil

  defp role_slug_map do
    Application.get_env(:fizz, :workos_role_slug_map, %{
      owner: "owner",
      admin: "admin",
      member: "member"
    })
  end

  defp user_management_module do
    Application.get_env(:fizz, :workos_user_management_module, WorkOS.UserManagement)
  end
end
