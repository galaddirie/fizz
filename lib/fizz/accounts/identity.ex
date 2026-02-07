defmodule Fizz.Accounts.Identity do
  @moduledoc """
  WorkOS-first identity and tenancy primitives.

  The local database stores app-specific tenancy/workspace records and mirrors
  WorkOS external identifiers for organizations and memberships.
  """

  import Ecto.Query, warn: false

  alias Fizz.Accounts

  alias Fizz.Accounts.{
    Scope,
    Tenant,
    TenantMembership,
    User,
    Workspace,
    WorkspaceMembership,
    WorkOS
  }

  alias Fizz.Repo

  @doc """
  Lists tenants accessible to the current user scope.
  """
  def list_tenants(%Scope{user: %User{id: user_id}}) do
    from(t in Tenant,
      join: tm in TenantMembership,
      on: tm.tenant_id == t.id,
      where: tm.user_id == ^user_id,
      order_by: [asc: t.name]
    )
    |> Repo.all()
  end

  def list_tenants(_), do: []

  @doc """
  Creates a tenant and owner membership for the scope user.

  WorkOS sync defaults to `WorkOS.enabled?/0`, but can be overridden with
  `sync_workos: true | false` for explicit control in tests and scripts.
  """
  def create_tenant(scope, attrs, opts \\ [])

  def create_tenant(%Scope{user: %User{} = user}, attrs, opts) do
    tenant_attrs =
      attrs
      |> normalize_attrs()
      |> ensure_slug(:name)

    Repo.transact(fn ->
      with {:ok, tenant} <- insert_tenant(tenant_attrs),
           {:ok, membership} <- upsert_tenant_membership(tenant.id, user.id, %{role: :owner}),
           {:ok, sync_payload} <- maybe_sync_tenant_and_owner(tenant, user, :owner, opts),
           {:ok, tenant} <- maybe_store_workos_org_id(tenant, sync_payload.organization_id),
           {:ok, _membership} <-
             maybe_store_workos_membership_id(membership, sync_payload.membership_id),
           {:ok, _user} <- maybe_store_workos_user_id(user, sync_payload.user_id),
           :ok <-
             maybe_emit_audit_event(
               tenant,
               user,
               "tenant.created",
               [%{type: "tenant", id: Integer.to_string(tenant.id)}],
               %{tenant_slug: tenant.slug}
             ) do
        {:ok, tenant}
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def create_tenant(_scope, _attrs, _opts), do: {:error, :unauthenticated}

  @doc """
  Builds a tenant/workspace-aware scope for the current user.
  """
  def build_scope(scope, tenant_id, opts \\ [])

  def build_scope(%Scope{user: %User{id: user_id}} = scope, tenant_id, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)

    with {:ok, tenant_membership} <- fetch_tenant_membership(tenant_id, user_id),
         %Tenant{} = tenant <- Repo.get(Tenant, tenant_id),
         {:ok, workspace_membership, workspace} <-
           fetch_workspace_membership(tenant_id, user_id, workspace_id, tenant_membership.role) do
      resolved_scope =
        scope
        |> Scope.with_tenant(tenant)
        |> Scope.with_tenant_role(tenant_membership.role)
        |> maybe_put_workspace(workspace)
        |> Scope.with_workspace_role(workspace_role(workspace_membership))

      {:ok, resolved_scope}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :tenant_not_found}
    end
  end

  def build_scope(_scope, _tenant_id, _opts), do: {:error, :unauthenticated}

  @doc """
  Creates a workspace inside the active tenant.
  """
  def create_workspace(%Scope{tenant: %Tenant{} = tenant} = scope, attrs) do
    with :ok <- require_tenant_admin(scope) do
      workspace_attrs =
        attrs
        |> normalize_attrs()
        |> ensure_slug(:name)

      Repo.transact(fn ->
        workspace_changeset =
          %Workspace{tenant_id: tenant.id}
          |> Workspace.changeset(workspace_attrs)

        with {:ok, workspace} <- Repo.insert(workspace_changeset),
             {:ok, _membership} <- maybe_add_workspace_admin_membership(workspace, scope.user),
             :ok <-
               maybe_emit_audit_event(
                 tenant,
                 scope.user,
                 "workspace.created",
                 [
                   %{type: "tenant", id: Integer.to_string(tenant.id)},
                   %{type: "workspace", id: Integer.to_string(workspace.id)}
                 ],
                 %{workspace_slug: workspace.slug}
               ) do
          {:ok, workspace}
        else
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  def create_workspace(_scope, _attrs), do: {:error, :tenant_scope_required}

  @doc """
  Lists workspaces for the active tenant and current user scope.
  """
  def list_workspaces(%Scope{tenant: %Tenant{id: tenant_id}, user: %User{id: user_id}} = scope) do
    query =
      if Scope.tenant_admin?(scope) do
        from(w in Workspace,
          where: w.tenant_id == ^tenant_id,
          order_by: [asc: w.name]
        )
      else
        from(w in Workspace,
          join: wm in WorkspaceMembership,
          on: wm.workspace_id == w.id,
          where: w.tenant_id == ^tenant_id and wm.user_id == ^user_id,
          order_by: [asc: w.name]
        )
      end

    {:ok, Repo.all(query)}
  end

  def list_workspaces(_scope), do: {:error, :tenant_scope_required}

  @doc """
  Adds or updates tenant membership for a user.
  """
  def add_tenant_member(%Scope{tenant: %Tenant{} = tenant} = scope, %User{} = user, attrs) do
    with :ok <- require_tenant_admin(scope) do
      attrs = attrs |> normalize_attrs() |> Map.take([:role])

      Repo.transact(fn ->
        with {:ok, membership} <- upsert_tenant_membership(tenant.id, user.id, attrs),
             {:ok, sync_payload} <- maybe_sync_tenant_member(tenant, user, membership.role),
             {:ok, membership} <-
               maybe_store_workos_membership_id(membership, sync_payload.membership_id),
             {:ok, _user} <- maybe_store_workos_user_id(user, sync_payload.user_id),
             :ok <-
               maybe_emit_audit_event(
                 tenant,
                 scope.user,
                 "tenant.member_upserted",
                 [
                   %{type: "tenant", id: Integer.to_string(tenant.id)},
                   %{type: "user", id: Integer.to_string(user.id)}
                 ],
                 %{role: to_string(membership.role)}
               ) do
          {:ok, membership}
        else
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  def add_tenant_member(_scope, _user, _attrs), do: {:error, :tenant_scope_required}

  @doc """
  Adds or updates workspace membership for a user.
  """
  def add_workspace_member(
        %Scope{tenant: %Tenant{id: tenant_id}, user: %User{id: actor_user_id}} = scope,
        workspace_id,
        %User{} = user,
        attrs
      ) do
    attrs = attrs |> normalize_attrs() |> normalize_integer_field(:workspace_id)

    with {:ok, workspace} <- fetch_workspace(tenant_id, workspace_id),
         :ok <- require_workspace_admin(scope, workspace.id, actor_user_id) do
      attrs = Map.take(attrs, [:role, :access_purpose])

      membership =
        Repo.get_by(WorkspaceMembership, workspace_id: workspace.id, user_id: user.id) ||
          %WorkspaceMembership{workspace_id: workspace.id, user_id: user.id}

      Repo.transact(fn ->
        with {:ok, membership} <-
               membership |> WorkspaceMembership.changeset(attrs) |> Repo.insert_or_update(),
             :ok <-
               maybe_emit_audit_event(
                 scope.tenant,
                 scope.user,
                 "workspace.member_upserted",
                 [
                   %{type: "workspace", id: Integer.to_string(workspace.id)},
                   %{type: "user", id: Integer.to_string(user.id)}
                 ],
                 %{role: to_string(membership.role)}
               ) do
          {:ok, membership}
        else
          {:error, reason} -> {:error, reason}
        end
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def add_workspace_member(_scope, _workspace_id, _user, _attrs),
    do: {:error, :tenant_scope_required}

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

  defp insert_tenant(attrs) do
    %Tenant{}
    |> Tenant.changeset(attrs)
    |> Repo.insert()
  end

  defp upsert_tenant_membership(tenant_id, user_id, attrs) do
    membership =
      Repo.get_by(TenantMembership, tenant_id: tenant_id, user_id: user_id) ||
        %TenantMembership{tenant_id: tenant_id, user_id: user_id}

    membership
    |> TenantMembership.changeset(attrs)
    |> Repo.insert_or_update()
  end

  defp fetch_tenant_membership(tenant_id, user_id) do
    case Repo.get_by(TenantMembership, tenant_id: tenant_id, user_id: user_id) do
      %TenantMembership{} = membership -> {:ok, membership}
      nil -> {:error, :forbidden}
    end
  end

  defp fetch_workspace_membership(_tenant_id, _user_id, nil, _tenant_role), do: {:ok, nil, nil}

  defp fetch_workspace_membership(tenant_id, user_id, workspace_id, tenant_role) do
    with {:ok, workspace} <- fetch_workspace(tenant_id, workspace_id) do
      case Repo.get_by(WorkspaceMembership, workspace_id: workspace.id, user_id: user_id) do
        %WorkspaceMembership{} = membership -> {:ok, membership, workspace}
        nil when tenant_role in [:owner, :admin] -> {:ok, nil, workspace}
        nil -> {:error, :workspace_forbidden}
      end
    end
  end

  defp fetch_workspace(tenant_id, workspace_id) when is_binary(workspace_id) do
    case Integer.parse(workspace_id) do
      {id, ""} -> fetch_workspace(tenant_id, id)
      _ -> {:error, :workspace_not_found}
    end
  end

  defp fetch_workspace(tenant_id, workspace_id) when is_integer(workspace_id) do
    case Repo.get_by(Workspace, id: workspace_id, tenant_id: tenant_id) do
      %Workspace{} = workspace -> {:ok, workspace}
      nil -> {:error, :workspace_not_found}
    end
  end

  defp fetch_workspace(_tenant_id, _workspace_id), do: {:error, :workspace_not_found}

  defp workspace_role(nil), do: nil
  defp workspace_role(%WorkspaceMembership{role: role}), do: role

  defp maybe_put_workspace(scope, nil), do: scope
  defp maybe_put_workspace(scope, workspace), do: Scope.with_workspace(scope, workspace)

  defp require_tenant_admin(scope) do
    if Scope.tenant_admin?(scope) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp require_workspace_admin(scope, workspace_id, actor_user_id) do
    cond do
      Scope.tenant_admin?(scope) ->
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

  defp maybe_sync_tenant_and_owner(tenant, user, role, opts) do
    sync_workos? = Keyword.get(opts, :sync_workos, WorkOS.enabled?())

    if sync_workos? do
      WorkOS.sync_tenant_and_owner(tenant, user, role)
    else
      {:ok, %{organization_id: nil, membership_id: nil, user_id: nil}}
    end
  end

  defp maybe_sync_tenant_member(tenant, user, role) do
    if WorkOS.enabled?() do
      WorkOS.ensure_organization_membership(tenant, user, role)
    else
      {:ok, %{membership_id: nil, user_id: nil}}
    end
  end

  defp maybe_store_workos_org_id(%Tenant{} = tenant, nil), do: {:ok, tenant}

  defp maybe_store_workos_org_id(%Tenant{} = tenant, workos_organization_id) do
    tenant
    |> Tenant.changeset(%{workos_organization_id: workos_organization_id})
    |> Repo.update()
  end

  defp maybe_store_workos_membership_id(%TenantMembership{} = membership, nil),
    do: {:ok, membership}

  defp maybe_store_workos_membership_id(%TenantMembership{} = membership, workos_membership_id) do
    membership
    |> TenantMembership.changeset(%{workos_organization_membership_id: workos_membership_id})
    |> Repo.update()
  end

  defp maybe_store_workos_user_id(%User{} = user, nil), do: {:ok, user}

  defp maybe_store_workos_user_id(%User{workos_user_id: existing} = user, workos_user_id)
       when is_binary(existing) and existing == workos_user_id,
       do: {:ok, user}

  defp maybe_store_workos_user_id(%User{} = user, workos_user_id) do
    user
    |> Accounts.User.workos_changeset(%{workos_user_id: workos_user_id})
    |> Repo.update()
  end

  defp maybe_emit_audit_event(%Tenant{} = tenant, %User{} = actor, action, targets, context) do
    case WorkOS.create_audit_event(tenant, actor, action, targets, context) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp maybe_emit_audit_event(_tenant, _actor, _action, _targets, _context), do: :ok

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

  defp normalize_integer_field(attrs, key) do
    case Map.get(attrs, key) do
      value when is_integer(value) ->
        attrs

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> Map.put(attrs, key, parsed)
          _ -> attrs
        end

      _ ->
        attrs
    end
  end

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
end
