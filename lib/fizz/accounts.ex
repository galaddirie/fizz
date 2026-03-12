defmodule Fizz.Accounts do
  @moduledoc """
  Identity and multi-tenancy context, built on WorkOS as the external identity provider.

  ## Entity hierarchy

      Organizations (WorkOS) → Projects (local) → Memberships (local)

  **Organizations** are managed entirely in WorkOS — they are never stored locally.
  An organization represents a company, team, or billing entity. Users belong to
  one or more organizations via WorkOS organization memberships.

  **Projects** are a local sub-organizational unit scoped to a single WorkOS
  organization. They provide a generic grouping concept for related resources and
  work — more focused than an organization, more generic than a "project". In a
  B2B SaaS context a client typically maps to one project, or to multiple
  projects for larger clients.

  **Project memberships** link a user to a project with a specific role
  (`:admin`, `:member`, or `:viewer`).

  ## Authorization

  All operations require a `Fizz.Accounts.Scope` struct carrying the resolved
  user, organization, and project context. The scope is built via `build_scope/3`
  after the user selects an organization and (optionally) a project.

  ## Roles

  * **Organization roles** (sourced from WorkOS): `:owner` > `:admin` > `:member`
  * **Project roles** (local): `:admin` > `:member` > `:viewer`

  Organization owners and admins implicitly have access to all projects in
  their organization.

  ## WorkOS integration

  Authentication (AuthKit), organization membership, and audit logging are
  delegated to WorkOS through `Fizz.Accounts.WorkOS`.
  """

  import Ecto.Query, warn: false

  import Fizz.Accounts.WorkOS.Helpers, only: [membership_role_slugs: 1]

  alias Fizz.Accounts.{
    Scope,
    User,
    WorkOS,
    Project,
    ProjectMembership
  }

  alias Fizz.Repo

  ## Organization & project

  @doc """
  Organizations are owned by WorkOS and are no longer stored locally.
  """
  def list_organizations(_scope), do: []

  @doc """
  Creates a WorkOS organization and adds the current user as owner.
  """
  def create_organization(scope, attrs, opts \\ [])

  def create_organization(
        %Scope{user: %User{workos_user_id: workos_user_id}} = _scope,
        %{name: name},
        _opts
      )
      when is_binary(workos_user_id) and is_binary(name) do
    with {:ok, organization} <- WorkOS.create_workos_organization(name),
         {:ok, _membership} <-
           WorkOS.create_organization_membership(workos_user_id, organization.id, "owner") do
      {:ok, %{organization_id: organization.id, name: organization.name}}
    end
  end

  def create_organization(%Scope{user: %User{}}, _attrs, _opts),
    do: {:error, :missing_workos_user_id}

  def create_organization(_scope, _attrs, _opts), do: {:error, :unauthenticated}

  @doc """
  Ensures the user has at least one organization.

  If the user has no organizations, a personal org is auto-provisioned
  named "<email_prefix>'s Organization".
  """
  @spec ensure_personal_organization(Scope.t() | nil) :: [map()]
  def ensure_personal_organization(%Scope{user: %User{email: email}} = scope) do
    case list_user_workos_organizations(scope) do
      [] ->
        prefix = email |> String.split("@") |> List.first()
        org_name = "#{prefix}'s Organization"

        case create_organization(scope, %{name: org_name}) do
          {:ok, org} ->
            [
              %{
                organization_id: org.organization_id,
                local_organization_id: nil,
                organization_name: org.name,
                role: :owner
              }
            ]

          {:error, _reason} ->
            []
        end

      organizations ->
        organizations
    end
  end

  def ensure_personal_organization(_scope), do: []

  @doc """
  Builds a WorkOS organization/project-aware scope for the current user.
  """
  def build_scope(scope, organization_id, opts \\ [])

  def build_scope(
        %Scope{user: %User{id: user_id, workos_user_id: workos_user_id}} = scope,
        organization_id,
        opts
      )
      when is_binary(workos_user_id) and is_binary(organization_id) do
    project_id = Keyword.get(opts, :project_id)

    with {:ok, membership} <-
           WorkOS.get_user_organization_membership(workos_user_id, organization_id),
         organization_role <- organization_role_from_membership(membership),
         {:ok, project_membership, project} <-
           fetch_project_membership(
             organization_id,
             user_id,
             project_id,
             organization_role
           ) do
      resolved_scope =
        scope
        |> Scope.with_organization_id(organization_id)
        |> Scope.with_organization_role(organization_role)
        |> maybe_put_project(project)
        |> Scope.with_project_role(project_role(project_membership))

      {:ok, resolved_scope}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def build_scope(%Scope{user: %User{}}, _organization_id, _opts),
    do: {:error, :missing_workos_user_id}

  def build_scope(_scope, _organization_id, _opts), do: {:error, :unauthenticated}

  @doc """
  Creates a project inside the active WorkOS organization.
  """
  def create_project(%Scope{organization_id: organization_id} = scope, attrs)
      when is_binary(organization_id) do
    with :ok <- require_organization_admin(scope) do
      project_attrs =
        attrs
        |> normalize_attrs()
        |> ensure_slug(:name)

      Repo.transaction(fn ->
        project_changeset =
          %Project{workos_organization_id: organization_id}
          |> Project.changeset(project_attrs)

        with {:ok, project} <- Repo.insert(project_changeset),
             {:ok, _membership} <- maybe_add_project_admin_membership(project, scope.user),
             :ok <-
               maybe_emit_audit_event(
                 organization_id,
                 scope.user,
                 "project.created",
                 [
                   %{type: "organization", id: organization_id},
                   %{type: "project", id: to_string(project.id)}
                 ],
                 %{project_slug: project.slug}
               ) do
          project
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> unwrap_transaction()
    end
  end

  def create_project(_scope, _attrs), do: {:error, :organization_scope_required}

  @doc """
  Lists projects for the active WorkOS organization and current user scope.
  """
  def list_projects(%Scope{organization_id: organization_id, user: %User{id: user_id}} = scope)
      when is_binary(organization_id) do
    query =
      if Scope.organization_admin?(scope) do
        from(project in Project,
          where: project.workos_organization_id == ^organization_id,
          order_by: [asc: project.name]
        )
      else
        from(project in Project,
          join: membership in ProjectMembership,
          on: membership.project_id == project.id,
          where:
            project.workos_organization_id == ^organization_id and
              membership.user_id == ^user_id,
          order_by: [asc: project.name]
        )
      end

    {:ok, Repo.all(query)}
  end

  def list_projects(_scope), do: {:error, :organization_scope_required}

  @doc """
  Fetches a project by local id.
  """
  @spec get_project(String.t()) :: Project.t() | nil
  def get_project(project_id) when is_binary(project_id) do
    Repo.get(Project, project_id)
  end

  def get_project(_project_id), do: nil

  @doc """
  Builds and returns a project-aware scope for the given project id.
  """
  @spec build_scope_for_project(Scope.t() | nil, String.t()) ::
          {:ok, Scope.t()}
          | {:error, :project_not_found | :forbidden | :unauthenticated | term()}
  def build_scope_for_project(%Scope{} = scope, project_id) when is_binary(project_id) do
    case Repo.get(Project, project_id) do
      %Project{} = project ->
        build_scope(scope, project.workos_organization_id, project_id: project.id)

      nil ->
        {:error, :project_not_found}
    end
  end

  def build_scope_for_project(_scope, _project_id), do: {:error, :unauthenticated}

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
  Adds or updates project membership for a user.
  """
  def add_project_member(
        %Scope{organization_id: organization_id, user: %User{id: actor_user_id}} = scope,
        project_id,
        %User{} = user,
        attrs
      )
      when is_binary(organization_id) do
    attrs = normalize_attrs(attrs)

    with {:ok, project} <- fetch_project(organization_id, project_id),
         :ok <- require_project_admin(scope, project.id, actor_user_id) do
      attrs = Map.take(attrs, [:role, :access_purpose])

      membership =
        Repo.get_by(ProjectMembership, project_id: project.id, user_id: user.id) ||
          %ProjectMembership{project_id: project.id, user_id: user.id}

      Repo.transaction(fn ->
        with {:ok, membership} <-
               membership |> ProjectMembership.changeset(attrs) |> Repo.insert_or_update(),
             :ok <-
               maybe_emit_audit_event(
                 organization_id,
                 scope.user,
                 "project.member_upserted",
                 [
                   %{type: "project", id: to_string(project.id)},
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

  def add_project_member(_scope, _project_id, _user, _attrs),
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

  defp fetch_project_membership(_organization_id, _user_id, nil, _organization_role),
    do: {:ok, nil, nil}

  defp fetch_project_membership(organization_id, user_id, project_id, organization_role) do
    with {:ok, project} <- fetch_project(organization_id, project_id) do
      case Repo.get_by(ProjectMembership, project_id: project.id, user_id: user_id) do
        %ProjectMembership{} = membership -> {:ok, membership, project}
        nil when organization_role in [:owner, :admin] -> {:ok, nil, project}
        nil -> {:error, :project_forbidden}
      end
    end
  end

  defp fetch_project(organization_id, %Project{id: project_id}) do
    fetch_project(organization_id, project_id)
  end

  defp fetch_project(organization_id, project_id)
       when is_binary(organization_id) and is_binary(project_id) do
    case Repo.get_by(Project, id: project_id, workos_organization_id: organization_id) do
      %Project{} = project -> {:ok, project}
      nil -> {:error, :project_not_found}
    end
  end

  defp fetch_project(_organization_id, _project_id), do: {:error, :project_not_found}

  defp project_role(nil), do: nil
  defp project_role(%ProjectMembership{role: role}), do: role

  defp maybe_put_project(scope, nil), do: scope
  defp maybe_put_project(scope, project), do: Scope.with_project(scope, project)

  defp require_organization_admin(scope) do
    if Scope.organization_admin?(scope) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp require_project_admin(scope, project_id, actor_user_id) do
    cond do
      Scope.organization_admin?(scope) ->
        :ok

      scope.project && scope.project.id == project_id && Scope.project_admin?(scope) ->
        :ok

      true ->
        case Repo.get_by(ProjectMembership, project_id: project_id, user_id: actor_user_id) do
          %ProjectMembership{role: :admin} -> :ok
          _ -> {:error, :forbidden}
        end
    end
  end

  defp maybe_add_project_admin_membership(_project, nil), do: {:ok, :noop}

  defp maybe_add_project_admin_membership(%Project{id: project_id}, %User{id: user_id}) do
    membership =
      Repo.get_by(ProjectMembership, project_id: project_id, user_id: user_id) ||
        %ProjectMembership{project_id: project_id, user_id: user_id}

    membership
    |> ProjectMembership.changeset(%{role: :admin})
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

  defdelegate generate_workos_pkce_code_verifier(bytes \\ 32),
    to: WorkOS,
    as: :generate_code_verifier

  defdelegate workos_pkce_code_challenge_s256(code_verifier),
    to: WorkOS,
    as: :code_challenge_s256

  defdelegate workos_authorization_url(params), to: WorkOS, as: :authorization_url

  @doc """
  Lists WorkOS organizations the current scope user belongs to.
  """
  @spec list_user_workos_organizations(Scope.t() | nil) :: [map()]
  defdelegate list_user_workos_organizations(scope),
    to: Fizz.Accounts.WorkOS.Directory,
    as: :list_user_organizations

  @doc """
  Generates a WorkOS widget token for the given organization.
  """
  @spec generate_widget_token(Scope.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_widget_token(scope, organization_id) do
    Fizz.Accounts.WorkOS.Tokens.generate_widget_token(scope, organization_id, [])
  end

  @doc """
  Fetches a Pipes provider access token for the current scope user.
  """
  @spec get_pipes_access_token(Scope.t() | nil, String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  defdelegate get_pipes_access_token(scope, provider, organization_id),
    to: Fizz.Accounts.WorkOS.Tokens

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

  @doc """
  No-op local session revocation. WorkOS is the session source of truth.

  We keep this function for compatibility with existing webhook handling paths.
  """
  def revoke_user_sessions_by_workos_user_id(workos_user_id) when is_binary(workos_user_id),
    do: :ok

  def revoke_user_sessions_by_workos_user_id(_workos_user_id),
    do: {:error, :invalid_workos_user_id}

  @doc """
  Broadcasts a disconnect for the given WorkOS session id via PubSub.
  """
  def disconnect_workos_session(session_id)
      when is_binary(session_id) and byte_size(session_id) > 0 do
    topic = "workos_sessions:#{Base.url_encode64(session_id, padding: false)}"
    FizzWeb.Endpoint.broadcast(topic, "disconnect", %{})
  end

  def disconnect_workos_session(_session_id), do: :ok

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
