defmodule Fizz.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false

  alias Fizz.Accounts.{
    Scope,
    User,
    UserToken,
    WorkOS,
    Workspace,
    WorkspaceMembership
  }

  alias Fizz.Repo

  ## Organization & Workspace

  @doc """
  Organizations are owned by WorkOS and are no longer stored locally.
  """
  def list_organizations(_scope), do: []

  @doc """
  Organization creation is owned by WorkOS.
  """
  def create_organization(_scope, _attrs, _opts \\ []),
    do: {:error, :organization_managed_by_workos}

  @doc """
  Builds a WorkOS organization/workspace-aware scope for the current user.
  """
  def build_scope(scope, organization_id, opts \\ [])

  def build_scope(
        %Scope{user: %User{id: user_id, workos_user_id: workos_user_id}} = scope,
        organization_id,
        opts
      )
      when is_binary(workos_user_id) and is_binary(organization_id) do
    workspace_id = Keyword.get(opts, :workspace_id)

    with {:ok, membership} <-
           WorkOS.get_user_organization_membership(workos_user_id, organization_id),
         organization_role <- organization_role_from_membership(membership),
         {:ok, workspace_membership, workspace} <-
           fetch_workspace_membership(
             organization_id,
             user_id,
             workspace_id,
             organization_role
           ) do
      resolved_scope =
        scope
        |> Scope.with_organization_id(organization_id)
        |> Scope.with_organization_role(organization_role)
        |> maybe_put_workspace(workspace)
        |> Scope.with_workspace_role(workspace_role(workspace_membership))

      {:ok, resolved_scope}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def build_scope(%Scope{user: %User{}}, _organization_id, _opts),
    do: {:error, :missing_workos_user_id}

  def build_scope(_scope, _organization_id, _opts), do: {:error, :unauthenticated}

  @doc """
  Creates a workspace inside the active WorkOS organization.
  """
  def create_workspace(%Scope{organization_id: organization_id} = scope, attrs)
      when is_binary(organization_id) do
    with :ok <- require_organization_admin(scope) do
      workspace_attrs =
        attrs
        |> normalize_attrs()
        |> ensure_slug(:name)

      Repo.transaction(fn ->
        workspace_changeset =
          %Workspace{workos_organization_id: organization_id}
          |> Workspace.changeset(workspace_attrs)

        with {:ok, workspace} <- Repo.insert(workspace_changeset),
             {:ok, _membership} <- maybe_add_workspace_admin_membership(workspace, scope.user),
             :ok <-
               maybe_emit_audit_event(
                 organization_id,
                 scope.user,
                 "workspace.created",
                 [
                   %{type: "organization", id: organization_id},
                   %{type: "workspace", id: to_string(workspace.id)}
                 ],
                 %{workspace_slug: workspace.slug}
               ) do
          workspace
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> unwrap_transaction()
    end
  end

  def create_workspace(_scope, _attrs), do: {:error, :organization_scope_required}

  @doc """
  Lists workspaces for the active WorkOS organization and current user scope.
  """
  def list_workspaces(%Scope{organization_id: organization_id, user: %User{id: user_id}} = scope)
      when is_binary(organization_id) do
    query =
      if Scope.organization_admin?(scope) do
        from(w in Workspace,
          where: w.workos_organization_id == ^organization_id,
          order_by: [asc: w.name]
        )
      else
        from(w in Workspace,
          join: wm in WorkspaceMembership,
          on: wm.workspace_id == w.id,
          where: w.workos_organization_id == ^organization_id and wm.user_id == ^user_id,
          order_by: [asc: w.name]
        )
      end

    {:ok, Repo.all(query)}
  end

  def list_workspaces(_scope), do: {:error, :organization_scope_required}

  @doc """
  Adds or updates organization membership for a user in WorkOS.
  """
  def add_organization_member(
        %Scope{organization_id: organization_id} = scope,
        %User{} = user,
        attrs
      )
      when is_binary(organization_id) do
    with :ok <- require_organization_admin(scope) do
      attrs = attrs |> normalize_attrs() |> Map.take([:role])
      role = Map.get(attrs, :role, :member)

      with {:ok, sync_payload} <-
             WorkOS.ensure_organization_membership(organization_id, user, role),
           {:ok, _user} <- maybe_store_workos_user_id(user, sync_payload.user_id),
           :ok <-
             maybe_emit_audit_event(
               organization_id,
               scope.user,
               "organization.member_upserted",
               [
                 %{type: "organization", id: organization_id},
                 %{type: "user", id: to_string(user.id)}
               ],
               %{role: to_string(role)}
             ) do
        {:ok,
         %{
           organization_id: organization_id,
           user_id: user.id,
           role: role,
           workos_membership_id: sync_payload.membership_id
         }}
      end
    end
  end

  def add_organization_member(_scope, _user, _attrs), do: {:error, :organization_scope_required}

  @doc """
  Adds or updates workspace membership for a user.
  """
  def add_workspace_member(
        %Scope{organization_id: organization_id, user: %User{id: actor_user_id}} = scope,
        workspace_id,
        %User{} = user,
        attrs
      )
      when is_binary(organization_id) do
    attrs = normalize_attrs(attrs)

    with {:ok, workspace} <- fetch_workspace(organization_id, workspace_id),
         :ok <- require_workspace_admin(scope, workspace.id, actor_user_id) do
      attrs = Map.take(attrs, [:role, :access_purpose])

      membership =
        Repo.get_by(WorkspaceMembership, workspace_id: workspace.id, user_id: user.id) ||
          %WorkspaceMembership{workspace_id: workspace.id, user_id: user.id}

      Repo.transaction(fn ->
        with {:ok, membership} <-
               membership |> WorkspaceMembership.changeset(attrs) |> Repo.insert_or_update(),
             :ok <-
               maybe_emit_audit_event(
                 organization_id,
                 scope.user,
                 "workspace.member_upserted",
                 [
                   %{type: "workspace", id: to_string(workspace.id)},
                   %{type: "user", id: to_string(user.id)}
                 ],
                 %{role: to_string(membership.role)}
               ) do
          membership
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> unwrap_transaction()
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def add_workspace_member(_scope, _workspace_id, _user, _attrs),
    do: {:error, :organization_scope_required}

  @doc """
  Ensures the current user exists in WorkOS and persists its external ID.
  """
  def sync_user_to_workos(%Scope{user: %User{} = user}) do
    with {:ok, workos_user_id} <- WorkOS.ensure_user(user),
         {:ok, user} <- maybe_store_workos_user_id(user, workos_user_id) do
      {:ok, user}
    end
  end

  def sync_user_to_workos(_scope), do: {:error, :unauthenticated}

  defp fetch_workspace_membership(_organization_id, _user_id, nil, _organization_role),
    do: {:ok, nil, nil}

  defp fetch_workspace_membership(organization_id, user_id, workspace_id, organization_role) do
    with {:ok, workspace} <- fetch_workspace(organization_id, workspace_id) do
      case Repo.get_by(WorkspaceMembership, workspace_id: workspace.id, user_id: user_id) do
        %WorkspaceMembership{} = membership -> {:ok, membership, workspace}
        nil when organization_role in [:owner, :admin] -> {:ok, nil, workspace}
        nil -> {:error, :workspace_forbidden}
      end
    end
  end

  defp fetch_workspace(organization_id, %Workspace{id: workspace_id}) do
    fetch_workspace(organization_id, workspace_id)
  end

  defp fetch_workspace(organization_id, workspace_id)
       when is_binary(organization_id) and is_binary(workspace_id) do
    case Repo.get_by(Workspace, id: workspace_id, workos_organization_id: organization_id) do
      %Workspace{} = workspace -> {:ok, workspace}
      nil -> {:error, :workspace_not_found}
    end
  end

  defp fetch_workspace(_organization_id, _workspace_id), do: {:error, :workspace_not_found}

  defp workspace_role(nil), do: nil
  defp workspace_role(%WorkspaceMembership{role: role}), do: role

  defp maybe_put_workspace(scope, nil), do: scope
  defp maybe_put_workspace(scope, workspace), do: Scope.with_workspace(scope, workspace)

  defp require_organization_admin(scope) do
    if Scope.organization_admin?(scope) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp require_workspace_admin(scope, workspace_id, actor_user_id) do
    cond do
      Scope.organization_admin?(scope) ->
        :ok

      scope.workspace && scope.workspace.id == workspace_id && Scope.workspace_admin?(scope) ->
        :ok

      true ->
        case Repo.get_by(WorkspaceMembership, workspace_id: workspace_id, user_id: actor_user_id) do
          %WorkspaceMembership{role: :admin} -> :ok
          _ -> {:error, :forbidden}
        end
    end
  end

  defp maybe_add_workspace_admin_membership(_workspace, nil), do: {:ok, :noop}

  defp maybe_add_workspace_admin_membership(%Workspace{id: workspace_id}, %User{id: user_id}) do
    membership =
      Repo.get_by(WorkspaceMembership, workspace_id: workspace_id, user_id: user_id) ||
        %WorkspaceMembership{workspace_id: workspace_id, user_id: user_id}

    membership
    |> WorkspaceMembership.changeset(%{role: :admin})
    |> Repo.insert_or_update()
  end

  defp maybe_store_workos_user_id(%User{} = user, nil), do: {:ok, user}

  defp maybe_store_workos_user_id(%User{workos_user_id: existing} = user, workos_user_id)
       when is_binary(existing) and existing == workos_user_id,
       do: {:ok, user}

  defp maybe_store_workos_user_id(%User{} = user, workos_user_id) do
    user
    |> User.workos_changeset(%{workos_user_id: workos_user_id})
    |> Repo.update()
  end

  defp maybe_emit_audit_event(
         organization_id,
         %User{} = actor,
         action,
         targets,
         context
       )
       when is_binary(organization_id) do
    case WorkOS.create_audit_event(organization_id, actor, action, targets, context) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp maybe_emit_audit_event(_organization_id, _actor, _action, _targets, _context), do: :ok

  defp normalize_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_binary(key) ->
        case safe_to_existing_atom(key) do
          {:ok, atom} -> Map.put(acc, atom, value)
          :error -> acc
        end

      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      _, acc ->
        acc
    end)
  end

  defp normalize_attrs(_attrs), do: %{}

  defp ensure_slug(attrs, source_key) do
    case attr(attrs, :slug) do
      slug when is_binary(slug) and byte_size(slug) > 0 ->
        Map.put(attrs, :slug, slug)

      _ ->
        source_value =
          attrs
          |> attr(source_key)
          |> to_string()

        Map.put(attrs, :slug, slugify(source_value))
    end
  end

  defp slugify(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))

  defp safe_to_existing_atom(key) do
    try do
      {:ok, String.to_existing_atom(key)}
    rescue
      ArgumentError -> :error
    end
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp organization_role_from_membership(membership) do
    membership
    |> membership_role_slugs()
    |> Enum.find_value(:member, &normalize_role_slug/1)
  end

  defp normalize_role_slug(role_slug) when is_binary(role_slug) do
    case String.downcase(role_slug) do
      "owner" -> :owner
      "admin" -> :admin
      "member" -> :member
      _ -> nil
    end
  end

  defp normalize_role_slug(_role_slug), do: nil

  defp membership_role_slugs(membership) do
    role_slugs =
      membership
      |> read_value([:roles, "roles"])
      |> List.wrap()
      |> Enum.map(fn role -> read_value(role, [:slug, "slug"]) end)
      |> Enum.filter(&is_binary/1)

    primary_role_slug =
      case read_value(membership, [:role, "role", :role_slug, "role_slug"]) do
        %{} = role -> read_value(role, [:slug, "slug"])
        slug when is_binary(slug) -> slug
        _ -> nil
      end

    [primary_role_slug | role_slugs]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp read_value(data, keys) do
    Enum.find_value(keys, fn key ->
      case data do
        %{} -> Map.get(data, key)
        _ -> nil
      end
    end)
  end

  defdelegate workos_authorization_url(params), to: WorkOS, as: :authorization_url

  @doc """
  Lists WorkOS organizations the current scope user belongs to.
  """
  @spec list_user_workos_organizations(Scope.t() | nil) :: [map()]
  def list_user_workos_organizations(%Scope{user: %User{workos_user_id: workos_user_id}})
      when is_binary(workos_user_id) do
    case WorkOS.list_user_organization_memberships(workos_user_id) do
      {:ok, memberships} ->
        memberships
        |> Enum.map(&remote_organization_entry/1)
        |> Enum.filter(& &1)
        |> Enum.uniq_by(& &1.organization_id)
        |> Enum.sort_by(& &1.organization_name)

      {:error, _reason} ->
        []
    end
  end

  def list_user_workos_organizations(_scope), do: []

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

  defp user_has_workos_organization?(%User{workos_user_id: workos_user_id}, organization_id)
       when is_binary(workos_user_id) and is_binary(organization_id) do
    case WorkOS.user_has_organization_membership?(workos_user_id, organization_id) do
      {:ok, has_membership?} -> has_membership?
      {:error, _reason} -> false
    end
  end

  defp user_has_workos_organization?(_user, _organization_id), do: false

  defp remote_organization_entry(membership) do
    case membership_organization_id(membership) do
      organization_id when is_binary(organization_id) ->
        %{
          organization_id: organization_id,
          local_organization_id: nil,
          organization_name: membership_organization_name(membership, organization_id),
          role: organization_role_from_membership(membership)
        }

      _ ->
        nil
    end
  end

  defp membership_organization_id(%{organization_id: organization_id})
       when is_binary(organization_id),
       do: organization_id

  defp membership_organization_id(%{"organization_id" => organization_id})
       when is_binary(organization_id),
       do: organization_id

  defp membership_organization_id(_membership), do: nil

  defp membership_organization_name(membership, fallback_id) do
    case read_value(membership, [:organization, "organization"]) do
      %{} = organization ->
        read_value(organization, [:name, "name"]) || fallback_id

      _ ->
        fallback_id
    end
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
  Upserts a local user from a normalized WorkOS profile payload.
  """
  def upsert_user_from_workos_profile(%{id: id, email: email} = profile)
      when is_binary(id) and is_binary(email) do
    get_or_upsert_user_from_workos_profile(%{
      id: id,
      email: email,
      email_verified: Map.get(profile, :email_verified) in [true, "true"]
    })
  end

  def upsert_user_from_workos_profile(_profile), do: {:error, :invalid_workos_user_profile}

  @doc """
  Deletes a local user linked to the provided WorkOS user id.
  """
  def delete_user_by_workos_user_id(workos_user_id) when is_binary(workos_user_id) do
    case get_user_by_workos_user_id(workos_user_id) do
      %User{} = user ->
        case Repo.delete(user) do
          {:ok, _deleted_user} -> :ok
          {:error, reason} -> {:error, reason}
        end

      nil ->
        :ok
    end
  end

  def delete_user_by_workos_user_id(_workos_user_id), do: {:error, :invalid_workos_user_id}

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
  Exchanges a WorkOS AuthKit code and returns the local user plus WorkOS session payload.
  """
  def authenticate_user_with_workos_code_and_session(code, opts \\ %{}) when is_binary(code) do
    auth_params = %{
      code: code,
      code_verifier: opts[:code_verifier],
      ip_address: opts[:ip_address],
      user_agent: opts[:user_agent]
    }

    with {:ok, authentication} <- WorkOS.authenticate_with_code(auth_params),
         {:ok, profile} <- WorkOS.extract_user_profile(authentication),
         {:ok, user} <- get_or_upsert_user_from_workos_profile(profile),
         {:ok, workos_session} <- WorkOS.extract_session(authentication) do
      {:ok,
       %{user: user, workos_session: workos_session, workos_session_id: workos_session.session_id}}
    end
  end

  @doc """
  Refreshes a WorkOS AuthKit session and returns the local user plus rotated session payload.
  """
  def refresh_user_workos_session(refresh_token, opts \\ []) when is_binary(refresh_token) do
    auth_params = %{
      refresh_token: refresh_token,
      organization_id: opts[:organization_id],
      ip_address: opts[:ip_address],
      user_agent: opts[:user_agent]
    }

    with {:ok, authentication} <- WorkOS.authenticate_with_refresh_token(auth_params),
         {:ok, profile} <- WorkOS.extract_user_profile(authentication),
         {:ok, user} <- get_or_upsert_user_from_workos_profile(profile),
         {:ok, workos_session} <- WorkOS.extract_session(authentication) do
      {:ok,
       %{user: user, workos_session: workos_session, workos_session_id: workos_session.session_id}}
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

  @doc """
  Revokes all local sessions for a user identified by a WorkOS user id.
  """
  def revoke_user_sessions_by_workos_user_id(workos_user_id) when is_binary(workos_user_id) do
    case get_user_by_workos_user_id(workos_user_id) do
      %User{id: user_id} ->
        Repo.delete_all(from(token in UserToken, where: token.user_id == ^user_id))
        :ok

      nil ->
        :ok
    end
  end

  def revoke_user_sessions_by_workos_user_id(_workos_user_id),
    do: {:error, :invalid_workos_user_id}

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
end
