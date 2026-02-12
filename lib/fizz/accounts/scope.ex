defmodule Fizz.Accounts.Scope do
  @moduledoc """
  Caller scope used for authentication and role-based authorization.

  WorkOS is the source of truth for user/org identity. This scope mirrors
  the resolved organization/workspace context and effective local roles.
  """

  alias Fizz.Accounts.{Organization, User, Workspace}

  @organization_roles [:owner, :admin, :member]
  @workspace_roles [:admin, :member, :viewer]

  defstruct user: nil,
            actor: :anonymous,
            organization: nil,
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
          organization: %Organization{} | nil,
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
  Assigns the active organization on the scope.
  """
  @spec with_organization(t(), %Organization{}) :: t()
  def with_organization(%__MODULE__{} = scope, %Organization{} = organization),
    do: %{scope | organization: organization}

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
end
