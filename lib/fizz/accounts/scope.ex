defmodule Fizz.Accounts.Scope do
  @moduledoc """
  Caller scope used for authentication and role-based authorization.

  WorkOS is the source of truth for user/org identity. This scope mirrors
  the resolved WorkOS organization/workspace context and effective local roles.
  """

  alias Fizz.Accounts.{User, Workspace}
  alias Fizz.Executions.Execution
  alias Fizz.Workflows.Workflow

  @organization_roles [:owner, :admin, :member]
  @workspace_roles [:admin, :member, :viewer]
  @workspace_view_roles [:admin, :member, :viewer]
  @workspace_edit_roles [:admin, :member]

  defstruct user: nil,
            actor: :anonymous,
            organization_id: nil,
            workspace: nil,
            organization_role: nil,
            workspace_role: nil,
            metadata: %{}

  @type organization_role :: :owner | :admin | :member | nil
  @type workspace_role :: :admin | :member | :viewer | nil

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
  Whether scope has organization admin privileges.
  """
  @spec organization_admin?(t()) :: boolean()
  def organization_admin?(%__MODULE__{organization_role: role}) when role in [:owner, :admin],
    do: true

  def organization_admin?(%__MODULE__{}), do: false

  @doc """
  Whether scope has any organization membership.
  """
  @spec organization_member?(t()) :: boolean()
  def organization_member?(%__MODULE__{organization_role: role}) when role in @organization_roles,
    do: true

  def organization_member?(%__MODULE__{}), do: false

  @doc """
  Whether scope has workspace admin privileges.
  """
  @spec workspace_admin?(t()) :: boolean()
  def workspace_admin?(%__MODULE__{workspace_role: :admin}), do: true
  def workspace_admin?(%__MODULE__{}), do: false

  @doc """
  Whether scope can view a workflow in the active workspace.
  """
  @spec can_view_workflow?(t() | nil, Workflow.t() | map()) :: boolean()
  def can_view_workflow?(%__MODULE__{} = scope, %Workflow{} = workflow) do
    authenticated?(scope) and same_workspace?(scope, workflow) and can_read_workspace?(scope)
  end

  def can_view_workflow?(%__MODULE__{} = scope, %{workspace_id: _workspace_id} = workflow) do
    authenticated?(scope) and same_workspace?(scope, workflow) and can_read_workspace?(scope)
  end

  def can_view_workflow?(_scope, _workflow), do: false

  @doc """
  Whether scope can edit workflows in the active workspace.
  """
  @spec can_edit_workflow?(t() | nil, Workflow.t() | map()) :: boolean()
  def can_edit_workflow?(%__MODULE__{} = scope, %Workflow{} = workflow) do
    authenticated?(scope) and same_workspace?(scope, workflow) and can_write_workspace?(scope)
  end

  def can_edit_workflow?(%__MODULE__{} = scope, %{workspace_id: _workspace_id} = workflow) do
    authenticated?(scope) and same_workspace?(scope, workflow) and can_write_workspace?(scope)
  end

  def can_edit_workflow?(_scope, _workflow), do: false

  @doc """
  Compatibility helper kept for call sites that previously used owner checks.

  Under workspace-scoped auth, delete-level access follows edit permissions.
  """
  @spec owns_workflow?(t() | nil, Workflow.t() | map()) :: boolean()
  def owns_workflow?(scope, workflow), do: can_edit_workflow?(scope, workflow)

  @doc """
  Whether scope can view an execution through its workflow access.
  """
  @spec can_view_execution?(t() | nil, Execution.t() | map()) :: boolean()
  def can_view_execution?(scope, %Execution{workflow: %Workflow{} = workflow}),
    do: can_view_workflow?(scope, workflow)

  def can_view_execution?(scope, %{workflow: %{workspace_id: _workspace_id} = workflow}),
    do: can_view_workflow?(scope, workflow)

  def can_view_execution?(_scope, _execution), do: false

  @doc """
  Whether scope can create executions for a workflow.

  Nil scope is only allowed for production executions, with trigger restrictions
  enforced in the execution context.
  """
  @spec can_create_execution?(t() | nil, Workflow.t() | map(), Execution.execution_type() | nil) ::
          boolean()
  def can_create_execution?(%__MODULE__{} = scope, %Workflow{} = workflow, execution_type)
      when execution_type in [:production, :preview, :partial],
      do: can_edit_workflow?(scope, workflow)

  def can_create_execution?(
        %__MODULE__{} = scope,
        %{workspace_id: _workspace_id} = workflow,
        execution_type
      )
      when execution_type in [:production, :preview, :partial],
      do: can_edit_workflow?(scope, workflow)

  def can_create_execution?(nil, %{workspace_id: workspace_id}, :production)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0,
      do: true

  def can_create_execution?(_scope, _workflow, _execution_type), do: false

  defp same_workspace?(%__MODULE__{workspace: %Workspace{id: scope_workspace_id}}, %{
         workspace_id: workflow_workspace_id
       })
       when is_binary(scope_workspace_id) and is_binary(workflow_workspace_id),
       do: scope_workspace_id == workflow_workspace_id

  defp same_workspace?(_scope, _workflow), do: false

  defp can_read_workspace?(%__MODULE__{workspace_role: workspace_role})
       when workspace_role in @workspace_view_roles,
       do: true

  defp can_read_workspace?(%__MODULE__{} = scope), do: organization_admin?(scope)

  defp can_write_workspace?(%__MODULE__{workspace_role: workspace_role})
       when workspace_role in @workspace_edit_roles,
       do: true

  defp can_write_workspace?(%__MODULE__{} = scope), do: organization_admin?(scope)
end
