defmodule Fizz.Accounts.Scope do
  @moduledoc """
  Caller scope used for authentication and role-based authorization.

  WorkOS is the source of truth for user/org identity. This scope mirrors
  the resolved tenant/workspace context and effective local roles.
  """

  alias Fizz.Accounts.{Tenant, User, Workspace}

  @tenant_roles [:owner, :admin, :member]
  @workspace_roles [:admin, :member, :viewer]

  defstruct user: nil,
            actor: :anonymous,
            tenant: nil,
            workspace: nil,
            tenant_role: nil,
            workspace_role: nil,
            metadata: %{}

  @type tenant_role :: :owner | :admin | :member | nil
  @type workspace_role :: :admin | :member | :viewer | nil

  @typedoc "A resolved caller scope"
  @type t :: %__MODULE__{
          user: %User{} | nil,
          actor: :anonymous | :user,
          tenant: %Tenant{} | nil,
          workspace: %Workspace{} | nil,
          tenant_role: tenant_role(),
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
  Assigns the active tenant on the scope.
  """
  @spec with_tenant(t(), %Tenant{}) :: t()
  def with_tenant(%__MODULE__{} = scope, %Tenant{} = tenant), do: %{scope | tenant: tenant}

  @doc """
  Assigns the active workspace on the scope.
  """
  @spec with_workspace(t(), %Workspace{}) :: t()
  def with_workspace(%__MODULE__{} = scope, %Workspace{} = workspace),
    do: %{scope | workspace: workspace}

  @doc """
  Assigns the tenant role.
  """
  @spec with_tenant_role(t(), tenant_role()) :: t()
  def with_tenant_role(%__MODULE__{} = scope, role) when role in @tenant_roles,
    do: %{scope | tenant_role: role}

  def with_tenant_role(%__MODULE__{} = scope, nil), do: %{scope | tenant_role: nil}

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
  Whether scope has tenant admin privileges.
  """
  @spec tenant_admin?(t()) :: boolean()
  def tenant_admin?(%__MODULE__{tenant_role: role}) when role in [:owner, :admin], do: true
  def tenant_admin?(%__MODULE__{}), do: false

  @doc """
  Whether scope has any tenant membership.
  """
  @spec tenant_member?(t()) :: boolean()
  def tenant_member?(%__MODULE__{tenant_role: role}) when role in @tenant_roles, do: true
  def tenant_member?(%__MODULE__{}), do: false

  @doc """
  Whether scope has workspace admin privileges.
  """
  @spec workspace_admin?(t()) :: boolean()
  def workspace_admin?(%__MODULE__{workspace_role: :admin}), do: true
  def workspace_admin?(%__MODULE__{}), do: false
end
