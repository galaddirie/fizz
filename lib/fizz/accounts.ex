defmodule Fizz.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false

  alias Fizz.Accounts.{Identity, Scope, Tenant, TenantMembership, User, UserToken, WorkOS}
  alias Fizz.Repo

  ## Identity & Tenancy

  defdelegate list_tenants(scope), to: Identity
  defdelegate create_tenant(scope, attrs, opts \\ []), to: Identity
  defdelegate build_scope(scope, tenant_id, opts \\ []), to: Identity
  defdelegate list_workspaces(scope), to: Identity
  defdelegate create_workspace(scope, attrs), to: Identity
  defdelegate add_tenant_member(scope, user, attrs), to: Identity
  defdelegate add_workspace_member(scope, workspace_id, user, attrs), to: Identity
  defdelegate sync_user_to_workos(scope), to: Identity
  defdelegate workos_authorization_url(params), to: WorkOS, as: :authorization_url

  @doc """
  Lists WorkOS organizations the current scope user belongs to.
  """
  @spec list_user_workos_organizations(Scope.t() | nil) :: [map()]
  def list_user_workos_organizations(%Scope{user: %User{} = user}) do
    local_organizations = list_local_user_workos_organizations(user.id)

    remote_organizations =
      if local_organizations == [] do
        list_remote_user_workos_organizations(user, local_organizations)
      else
        []
      end

    local_organizations ++ remote_organizations
  end

  def list_user_workos_organizations(_scope), do: []

  defp list_local_user_workos_organizations(user_id) do
    from(tm in TenantMembership,
      join: t in Tenant,
      on: t.id == tm.tenant_id,
      where: tm.user_id == ^user_id and not is_nil(t.workos_organization_id),
      order_by: [asc: t.name],
      select: %{
        organization_id: t.workos_organization_id,
        tenant_id: t.id,
        tenant_name: t.name,
        role: tm.role
      }
    )
    |> Repo.all()
  end

  defp list_remote_user_workos_organizations(%User{workos_user_id: workos_user_id}, local_orgs)
       when is_binary(workos_user_id) do
    existing_organization_ids = MapSet.new(Enum.map(local_orgs, & &1.organization_id))

    case WorkOS.list_user_organization_memberships(workos_user_id) do
      {:ok, memberships} ->
        memberships
        |> Enum.map(&membership_organization_id/1)
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(existing_organization_ids, &1))
        |> Enum.map(&remote_organization_entry/1)
        |> Enum.sort_by(& &1.organization_id)

      {:error, _reason} ->
        []
    end
  end

  defp list_remote_user_workos_organizations(_user, _local_orgs), do: []

  @doc """
  Generates a WorkOS Pipes widget token for the given organization.
  """
  @spec generate_pipes_widget_token(Scope.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_pipes_widget_token(
        %Scope{user: %User{workos_user_id: workos_user_id} = user},
        organization_id
      )
      when is_binary(workos_user_id) and is_binary(organization_id) do
    if user_has_workos_organization?(user, organization_id) do
      WorkOS.generate_widget_token(%{
        organization_id: organization_id,
        user_id: workos_user_id,
        scopes: []
      })
    else
      {:error, :forbidden}
    end
  end

  def generate_pipes_widget_token(%Scope{}, _organization_id),
    do: {:error, :missing_workos_user_id}

  def generate_pipes_widget_token(_scope, _organization_id), do: {:error, :unauthenticated}

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
    if is_nil(organization_id) or user_has_workos_organization?(user, organization_id) do
      WorkOS.get_pipes_access_token(provider, workos_user_id, organization_id)
    else
      {:error, :forbidden}
    end
  end

  def get_pipes_access_token(%Scope{}, _provider, _organization_id),
    do: {:error, :missing_workos_user_id}

  def get_pipes_access_token(_scope, _provider, _organization_id), do: {:error, :unauthenticated}

  defp user_has_workos_organization?(%User{} = user, organization_id)
       when is_binary(organization_id) do
    local_user_has_workos_organization?(user.id, organization_id) ||
      remote_user_has_workos_organization?(user.workos_user_id, organization_id)
  end

  defp local_user_has_workos_organization?(user_id, organization_id) do
    from(tm in TenantMembership,
      join: t in Tenant,
      on: t.id == tm.tenant_id,
      where: tm.user_id == ^user_id and t.workos_organization_id == ^organization_id
    )
    |> Repo.exists?()
  end

  defp remote_user_has_workos_organization?(workos_user_id, organization_id)
       when is_binary(workos_user_id) and is_binary(organization_id) do
    case WorkOS.user_has_organization_membership?(workos_user_id, organization_id) do
      {:ok, has_membership?} -> has_membership?
      {:error, _reason} -> false
    end
  end

  defp remote_user_has_workos_organization?(_workos_user_id, _organization_id), do: false

  defp membership_organization_id(%{organization_id: organization_id})
       when is_binary(organization_id),
       do: organization_id

  defp membership_organization_id(%{"organization_id" => organization_id})
       when is_binary(organization_id),
       do: organization_id

  defp membership_organization_id(_membership), do: nil

  defp remote_organization_entry(organization_id) do
    %{
      organization_id: organization_id,
      tenant_id: nil,
      tenant_name: "WorkOS organization",
      role: nil
    }
  end

  ## Users

  @doc """
  Gets a user by email.
  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by WorkOS user id.
  """
  def get_user_by_workos_user_id(workos_user_id) when is_binary(workos_user_id) do
    Repo.get_by(User, workos_user_id: workos_user_id)
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Exchanges a WorkOS AuthKit code and returns/logically provisions the local user.
  """
  def authenticate_user_with_workos_code(code, opts \\ %{}) when is_binary(code) do
    with {:ok, %{user: user}} <- authenticate_user_with_workos_code_and_session(code, opts) do
      {:ok, user}
    end
  end

  @doc """
  Exchanges a WorkOS AuthKit code and returns the local user plus WorkOS session id.
  """
  def authenticate_user_with_workos_code_and_session(code, opts \\ %{}) when is_binary(code) do
    auth_params = %{
      code: code,
      ip_address: opts[:ip_address],
      user_agent: opts[:user_agent]
    }

    with {:ok, authentication} <- WorkOS.authenticate_with_code(auth_params),
         {:ok, profile} <- WorkOS.extract_user_profile(authentication),
         {:ok, user} <- get_or_upsert_user_from_workos_profile(profile) do
      {:ok, %{user: user, workos_session_id: extract_workos_session_id(authentication)}}
    end
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Deletes the signed session token.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token]))
    :ok
  end

  ## WorkOS profile sync

  defp get_or_upsert_user_from_workos_profile(%{id: workos_user_id, email: email} = profile) do
    case get_user_by_workos_user_id(workos_user_id) do
      %User{} = user ->
        update_user_from_workos_profile(user, profile)

      nil ->
        case get_user_by_email(email) do
          %User{workos_user_id: nil} = user ->
            update_user_from_workos_profile(user, profile)

          %User{workos_user_id: ^workos_user_id} = user ->
            update_user_from_workos_profile(user, profile)

          %User{} ->
            {:error, :workos_account_conflict}

          nil ->
            register_user_from_workos_profile(profile)
        end
    end
  end

  defp register_user_from_workos_profile(%{
         id: workos_user_id,
         email: email,
         email_verified: verified
       }) do
    confirmed_at = if verified, do: DateTime.utc_now(:second), else: nil

    %User{}
    |> User.workos_profile_changeset(%{
      email: email,
      workos_user_id: workos_user_id,
      confirmed_at: confirmed_at
    })
    |> Repo.insert()
  end

  defp update_user_from_workos_profile(
         %User{} = user,
         %{id: workos_user_id, email: email, email_verified: verified}
       ) do
    confirmed_at =
      if verified, do: user.confirmed_at || DateTime.utc_now(:second), else: user.confirmed_at

    user
    |> User.workos_profile_changeset(%{
      email: email,
      workos_user_id: workos_user_id,
      confirmed_at: confirmed_at
    })
    |> Repo.update()
  end

  defp extract_workos_session_id(%Elixir.WorkOS.UserManagement.Authentication{
         access_token: access_token
       })
       when is_binary(access_token) do
    with [_header, payload, _signature] <- String.split(access_token, ".", parts: 3),
         {:ok, decoded_payload} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded_payload),
         sid when is_binary(sid) <- claims["sid"] do
      sid
    else
      _ -> nil
    end
  end

  defp extract_workos_session_id(_), do: nil
end
