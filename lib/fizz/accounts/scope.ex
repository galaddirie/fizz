defmodule Fizz.Accounts.Scope do
  @moduledoc """
  Caller scope used for authentication and role-based authorization.

  WorkOS is the source of truth for user/org identity. This scope mirrors
  the resolved WorkOS organization/workspace context and effective local roles.
  """

  import Ecto.Query

  alias Fizz.Accounts.{User, Workspace, WorkspaceMembership}
  alias Fizz.Executions.Execution
  alias Fizz.Repo
  alias Fizz.Workflows.{Workflow, WorkflowShare}

  @organization_roles [:owner, :admin, :member]
  @workspace_roles [:admin, :member, :viewer]
  @workspace_edit_roles [:admin, :member]
  @workflow_share_edit_roles [:editor, :owner]
  @workflow_share_view_roles [:viewer, :editor, :owner]

  defstruct user: nil,
            actor: :anonymous,
            organization_id: nil,
            workspace: nil,
            organization_role: nil,
            workspace_role: nil,
            metadata: %{}

  @type organization_role :: :owner | :admin | :member | nil
  @type workspace_role :: :admin | :member | :viewer | nil
  @type query_permission :: :view | :edit

  @typedoc "A resolved caller scope"
  @type t :: %__MODULE__{
          user: %User{} | nil,
          actor: :anonymous | :user,
          organization_id: String.t() | nil,
          workspace: %Workspace{} | nil,
          organization_role: organization_role(),
          workspace_role: workspace_role(),
          metadata: map()
        }

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  @spec for_user(%User{} | nil) :: t() | nil
  def for_user(%User{} = user), do: %__MODULE__{user: user, actor: :user}
  def for_user(nil), do: nil

  @doc """
  Assigns the active WorkOS organization on the scope.
  """
  @spec with_organization_id(t(), String.t() | nil) :: t()
  def with_organization_id(%__MODULE__{} = scope, organization_id)
      when is_binary(organization_id) and byte_size(organization_id) > 0,
      do: %{scope | organization_id: organization_id}

  def with_organization_id(%__MODULE__{} = scope, nil), do: %{scope | organization_id: nil}

  @doc """
  Assigns the active workspace on the scope.
  """
  @spec with_workspace(t(), %Workspace{}) :: t()
  def with_workspace(%__MODULE__{} = scope, %Workspace{} = workspace),
    do: %{scope | workspace: workspace}

  def with_workspace(%__MODULE__{} = scope, nil), do: %{scope | workspace: nil}

  @doc """
  Assigns the organization role.
  """
  @spec with_organization_role(t(), organization_role()) :: t()
  def with_organization_role(%__MODULE__{} = scope, role) when role in @organization_roles,
    do: %{scope | organization_role: role}

  def with_organization_role(%__MODULE__{} = scope, nil), do: %{scope | organization_role: nil}

  @doc """
  Assigns the workspace role.
  """
  @spec with_workspace_role(t(), workspace_role()) :: t()
  def with_workspace_role(%__MODULE__{} = scope, role) when role in @workspace_roles,
    do: %{scope | workspace_role: role}

  def with_workspace_role(%__MODULE__{} = scope, nil), do: %{scope | workspace_role: nil}

  @doc """
  Whether the scope is authenticated.
  """
  @spec authenticated?(t() | nil) :: boolean()
  def authenticated?(%__MODULE__{actor: :user}), do: true
  def authenticated?(_), do: false

  @doc """
  Returns the user on the scope.
  """
  @spec user(t() | nil) :: User.t() | nil
  def user(%__MODULE__{user: user}), do: user
  def user(_), do: nil

  @doc """
  Returns the user id on the scope.
  """
  @spec user_id(t() | nil) :: Ecto.UUID.t() | nil
  def user_id(%__MODULE__{user: %User{id: id}}), do: id
  def user_id(_), do: nil

  @doc """
  Returns the active WorkOS organization id.
  """
  @spec organization_id(t() | nil) :: String.t() | nil
  def organization_id(%__MODULE__{organization_id: organization_id}), do: organization_id
  def organization_id(_), do: nil

  @doc """
  Returns the active workspace id.
  """
  @spec workspace_id(t() | nil) :: Ecto.UUID.t() | nil
  def workspace_id(%__MODULE__{workspace: %Workspace{id: workspace_id}}), do: workspace_id
  def workspace_id(_), do: nil

  @doc """
  Whether scope has organization admin privileges.
  """
  @spec organization_admin?(t() | nil) :: boolean()
  def organization_admin?(%__MODULE__{organization_role: role}) when role in [:owner, :admin],
    do: true

  def organization_admin?(_), do: false

  @doc """
  Whether scope has any organization membership.
  """
  @spec organization_member?(t() | nil) :: boolean()
  def organization_member?(%__MODULE__{organization_role: role}) when role in @organization_roles,
    do: true

  def organization_member?(_), do: false

  @doc """
  Whether scope has workspace admin privileges.
  """
  @spec workspace_admin?(t() | nil) :: boolean()
  def workspace_admin?(%__MODULE__{workspace_role: :admin}), do: true
  def workspace_admin?(_), do: false

  @doc """
  Whether scope has any workspace membership.
  """
  @spec workspace_member?(t() | nil) :: boolean()
  def workspace_member?(%__MODULE__{workspace_role: role}) when role in @workspace_roles, do: true
  def workspace_member?(_), do: false

  @doc """
  Query scope for workflow visibility/editability.

  ## Options

    * `:permission` - `:view` (default) or `:edit`
    * `:organization_id` - additional org filter (cannot widen beyond scope org)
    * `:workspace_id` - additional workspace filter (cannot widen beyond scope workspace)
    * `:owner_user_id` / `:user_id` - owner filter
  """
  @spec scope_workflows(t() | nil, Ecto.Queryable.t(), keyword()) :: Ecto.Query.t()
  def scope_workflows(scope, queryable \\ Workflow, opts \\ []) do
    permission = Keyword.get(opts, :permission, :view)

    queryable
    |> maybe_filter_workflow_organization(scope, opts)
    |> maybe_filter_workflow_workspace(scope, opts)
    |> maybe_filter_workflow_owner(opts)
    |> apply_workflow_permission(scope, permission)
  end

  @doc """
  Query scope for execution visibility/editability.

  ## Options

    * `:permission` - `:view` (default) or `:edit`
    * `:organization_id` - additional org filter (cannot widen beyond scope org)
    * `:workspace_id` - additional workspace filter (cannot widen beyond scope workspace)
    * `:workflow_id` - filter executions by workflow
    * `:triggered_by_user_id` / `:user_id` - filter by triggering user
  """
  @spec scope_executions(t() | nil, Ecto.Queryable.t(), keyword()) :: Ecto.Query.t()
  def scope_executions(scope, queryable \\ Execution, opts \\ []) do
    permission = Keyword.get(opts, :permission, :view)

    queryable
    |> maybe_filter_execution_organization(scope, opts)
    |> maybe_filter_execution_workspace(scope, opts)
    |> maybe_filter_execution_workflow(opts)
    |> maybe_filter_execution_triggered_by(opts)
    |> apply_execution_permission(scope, permission)
  end

  # ============================================================================
  # Workflow Permissions
  # ============================================================================

  @doc """
  Checks if the scope can view a workflow.
  """
  @spec can_view_workflow?(t() | nil, map() | Ecto.UUID.t()) :: boolean()
  def can_view_workflow?(scope, workflow_id) when is_binary(workflow_id) do
    accessible_workflow?(scope, workflow_id, :view)
  end

  def can_view_workflow?(scope, %{} = workflow) do
    case Map.get(workflow, :id) do
      id when is_binary(id) ->
        accessible_workflow?(scope, id, :view)

      _ ->
        owns_workflow?(scope, workflow) or Map.get(workflow, :public) == true
    end
  end

  def can_view_workflow?(_scope, _workflow), do: false

  @doc """
  Checks if the scope can edit a workflow.
  """
  @spec can_edit_workflow?(t() | nil, map() | Ecto.UUID.t()) :: boolean()
  def can_edit_workflow?(scope, workflow_id) when is_binary(workflow_id) do
    accessible_workflow?(scope, workflow_id, :edit)
  end

  def can_edit_workflow?(scope, %{} = workflow) do
    case Map.get(workflow, :id) do
      id when is_binary(id) -> accessible_workflow?(scope, id, :edit)
      _ -> owns_workflow?(scope, workflow)
    end
  end

  def can_edit_workflow?(_scope, _workflow), do: false

  @doc """
  Checks if the scope user owns a workflow.
  """
  @spec owns_workflow?(t() | nil, map()) :: boolean()
  def owns_workflow?(scope, %{} = workflow) do
    owner_id = Map.get(workflow, :user_id)
    current_user_id = user_id(scope)
    is_binary(owner_id) and owner_id == current_user_id
  end

  def owns_workflow?(_scope, _workflow), do: false

  # ============================================================================
  # Execution Permissions
  # ============================================================================

  @doc """
  Checks if the scope can view an execution.
  """
  @spec can_view_execution?(t() | nil, map() | Ecto.UUID.t()) :: boolean()
  def can_view_execution?(scope, execution_id) when is_binary(execution_id) do
    accessible_execution?(scope, execution_id, :view)
  end

  def can_view_execution?(scope, %{} = execution) do
    cond do
      is_binary(Map.get(execution, :id)) ->
        accessible_execution?(scope, execution.id, :view)

      is_map(Map.get(execution, :workflow)) ->
        can_view_workflow?(scope, execution.workflow)

      is_binary(Map.get(execution, :workflow_id)) ->
        can_view_workflow?(scope, execution.workflow_id)

      true ->
        false
    end
  end

  def can_view_execution?(_scope, _execution), do: false

  @doc """
  Checks if the scope can create an execution for the workflow.

  Preview/partial runs require edit access; production runs require view access.
  """
  @spec can_create_execution?(t() | nil, map() | Ecto.UUID.t(), atom() | String.t()) :: boolean()
  def can_create_execution?(scope, workflow, execution_type)
      when execution_type in [:preview, :partial, "preview", "partial"] do
    can_edit_workflow?(scope, workflow)
  end

  def can_create_execution?(scope, workflow, _execution_type) do
    can_view_workflow?(scope, workflow)
  end

  @doc """
  Edit sessions require workflow edit access.
  """
  @spec can_join_edit_session?(t() | nil, map() | Ecto.UUID.t()) :: boolean()
  def can_join_edit_session?(scope, workflow), do: can_edit_workflow?(scope, workflow)

  @doc """
  Edit session observation requires workflow view access.
  """
  @spec can_observe_edit_session?(t() | nil, map() | Ecto.UUID.t()) :: boolean()
  def can_observe_edit_session?(scope, workflow), do: can_view_workflow?(scope, workflow)

  # ============================================================================
  # Query filters
  # ============================================================================

  defp maybe_filter_workflow_organization(queryable, scope, opts) do
    query = from(w in queryable)

    case effective_organization_id(scope, opts) do
      :mismatch ->
        deny_query(query)

      nil ->
        query

      organization_id ->
        workspace_ids_query =
          from ws in Workspace,
            where: ws.workos_organization_id == ^organization_id,
            select: ws.id

        from w in query, where: w.workspace_id in subquery(workspace_ids_query)
    end
  end

  defp maybe_filter_workflow_workspace(queryable, scope, opts) do
    query = from(w in queryable)

    case effective_workspace_id(scope, opts) do
      :mismatch -> deny_query(query)
      nil -> query
      workspace_id -> from w in query, where: w.workspace_id == ^workspace_id
    end
  end

  defp maybe_filter_workflow_owner(queryable, opts) do
    owner_user_id = Keyword.get(opts, :owner_user_id) || Keyword.get(opts, :user_id)
    query = from(w in queryable)

    if is_binary(owner_user_id) do
      from w in query, where: w.user_id == ^owner_user_id
    else
      query
    end
  end

  defp maybe_filter_execution_organization(queryable, scope, opts) do
    query = from(e in queryable)

    case effective_organization_id(scope, opts) do
      :mismatch ->
        deny_query(query)

      nil ->
        query

      organization_id ->
        workspace_ids_query =
          from ws in Workspace,
            where: ws.workos_organization_id == ^organization_id,
            select: ws.id

        from e in query, where: e.workspace_id in subquery(workspace_ids_query)
    end
  end

  defp maybe_filter_execution_workspace(queryable, scope, opts) do
    query = from(e in queryable)

    case effective_workspace_id(scope, opts) do
      :mismatch -> deny_query(query)
      nil -> query
      workspace_id -> from e in query, where: e.workspace_id == ^workspace_id
    end
  end

  defp maybe_filter_execution_workflow(queryable, opts) do
    query = from(e in queryable)

    case Keyword.get(opts, :workflow_id) do
      workflow_id when is_binary(workflow_id) ->
        from e in query, where: e.workflow_id == ^workflow_id

      _ ->
        query
    end
  end

  defp maybe_filter_execution_triggered_by(queryable, opts) do
    query = from(e in queryable)
    triggered_by_user_id = Keyword.get(opts, :triggered_by_user_id) || Keyword.get(opts, :user_id)

    if is_binary(triggered_by_user_id) do
      from e in query, where: e.triggered_by_user_id == ^triggered_by_user_id
    else
      query
    end
  end

  defp apply_workflow_permission(_queryable, _scope, permission)
       when permission not in [:view, :edit] do
    raise ArgumentError, "unsupported workflow permission: #{inspect(permission)}"
  end

  defp apply_workflow_permission(queryable, scope, :view) do
    query = from(w in queryable)

    case user_id(scope) do
      nil ->
        from w in query, where: w.public == true

      user_id ->
        if organization_admin_with_active_scope?(scope) do
          query
        else
          query
          |> join(:left, [w], ws in WorkflowShare,
            on:
              ws.workflow_id == w.id and ws.user_id == ^user_id and
                ws.role in ^@workflow_share_view_roles
          )
          |> join(:left, [w], wm in WorkspaceMembership,
            on: wm.workspace_id == w.workspace_id and wm.user_id == ^user_id
          )
          |> where(
            [w, ..., ws, wm],
            w.public == true or w.user_id == ^user_id or not is_nil(ws.id) or not is_nil(wm.id)
          )
          |> distinct(true)
        end
    end
  end

  defp apply_workflow_permission(queryable, scope, :edit) do
    query = from(w in queryable)

    case user_id(scope) do
      nil ->
        deny_query(query)

      user_id ->
        if organization_admin_with_active_scope?(scope) do
          query
        else
          query
          |> join(:left, [w], ws in WorkflowShare,
            on:
              ws.workflow_id == w.id and ws.user_id == ^user_id and
                ws.role in ^@workflow_share_edit_roles
          )
          |> join(:left, [w], wm in WorkspaceMembership,
            on:
              wm.workspace_id == w.workspace_id and wm.user_id == ^user_id and
                wm.role in ^@workspace_edit_roles
          )
          |> where(
            [w, ..., ws, wm],
            w.user_id == ^user_id or not is_nil(ws.id) or not is_nil(wm.id)
          )
          |> distinct(true)
        end
    end
  end

  defp apply_execution_permission(_queryable, _scope, permission)
       when permission not in [:view, :edit] do
    raise ArgumentError, "unsupported execution permission: #{inspect(permission)}"
  end

  defp apply_execution_permission(queryable, scope, :view) do
    query = from(e in queryable)

    case user_id(scope) do
      nil ->
        query
        |> join(:inner, [e], w in Workflow, on: w.id == e.workflow_id)
        |> where([_e, ..., w], w.public == true)

      user_id ->
        if organization_admin_with_active_scope?(scope) do
          query
        else
          query
          |> join(:inner, [e], w in Workflow, on: w.id == e.workflow_id)
          |> join(:left, [e, ..., w], ws in WorkflowShare,
            on:
              ws.workflow_id == w.id and ws.user_id == ^user_id and
                ws.role in ^@workflow_share_view_roles
          )
          |> join(:left, [e], wm in WorkspaceMembership,
            on: wm.workspace_id == e.workspace_id and wm.user_id == ^user_id
          )
          |> where(
            [_e, ..., w, ws, wm],
            w.public == true or w.user_id == ^user_id or not is_nil(ws.id) or not is_nil(wm.id)
          )
          |> distinct(true)
        end
    end
  end

  defp apply_execution_permission(queryable, scope, :edit) do
    query = from(e in queryable)

    case user_id(scope) do
      nil ->
        deny_query(query)

      user_id ->
        if organization_admin_with_active_scope?(scope) do
          query
        else
          query
          |> join(:inner, [e], w in Workflow, on: w.id == e.workflow_id)
          |> join(:left, [e, ..., w], ws in WorkflowShare,
            on:
              ws.workflow_id == w.id and ws.user_id == ^user_id and
                ws.role in ^@workflow_share_edit_roles
          )
          |> join(:left, [e], wm in WorkspaceMembership,
            on:
              wm.workspace_id == e.workspace_id and wm.user_id == ^user_id and
                wm.role in ^@workspace_edit_roles
          )
          |> where(
            [_e, ..., w, ws, wm],
            w.user_id == ^user_id or not is_nil(ws.id) or not is_nil(wm.id)
          )
          |> distinct(true)
        end
    end
  end

  # ============================================================================
  # Authorization helpers
  # ============================================================================

  defp accessible_workflow?(scope, workflow_id, permission) do
    scope_workflows(scope, Workflow, permission: permission)
    |> where([w], w.id == ^workflow_id)
    |> Repo.exists?()
  end

  defp accessible_execution?(scope, execution_id, permission) do
    scope_executions(scope, Execution, permission: permission)
    |> where([e], e.id == ^execution_id)
    |> Repo.exists?()
  end

  defp organization_admin_with_active_scope?(%__MODULE__{} = scope) do
    organization_admin?(scope) and is_binary(scope.organization_id)
  end

  defp organization_admin_with_active_scope?(_), do: false

  defp effective_organization_id(scope, opts) do
    scope_organization_id = organization_id(scope)
    requested_organization_id = Keyword.get(opts, :organization_id)

    cond do
      is_binary(scope_organization_id) and is_binary(requested_organization_id) and
          scope_organization_id != requested_organization_id ->
        :mismatch

      is_binary(scope_organization_id) ->
        scope_organization_id

      is_binary(requested_organization_id) ->
        requested_organization_id

      true ->
        nil
    end
  end

  defp effective_workspace_id(scope, opts) do
    scope_workspace_id = workspace_id(scope)
    requested_workspace_id = Keyword.get(opts, :workspace_id)

    cond do
      is_binary(scope_workspace_id) and is_binary(requested_workspace_id) and
          scope_workspace_id != requested_workspace_id ->
        :mismatch

      is_binary(scope_workspace_id) ->
        scope_workspace_id

      is_binary(requested_workspace_id) ->
        requested_workspace_id

      true ->
        nil
    end
  end

  defp deny_query(queryable) do
    from item in queryable, where: false
  end
end
