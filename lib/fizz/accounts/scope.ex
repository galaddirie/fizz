defmodule Fizz.Accounts.Scope do
  @moduledoc """
  Caller scope used for authentication and role-based authorization.

  WorkOS is the source of truth for user/org identity. This scope mirrors
  the resolved WorkOS organization/project context and effective local roles.
  """

  alias Fizz.Accounts.{Project, User}

  @organization_roles [:owner, :admin, :member]
  @project_roles [:admin, :member, :viewer]

  defstruct user: nil,
            actor: :anonymous,
            organization_id: nil,
            project: nil,
            organization_role: nil,
            project_role: nil,
            metadata: %{}

  @type organization_role :: :owner | :admin | :member | nil
  @type project_role :: :admin | :member | :viewer | nil

  @typedoc "A resolved caller scope"
  @type t :: %__MODULE__{
          user: %User{} | nil,
          actor: :anonymous | :user,
          organization_id: String.t() | nil,
          project: %Project{} | nil,
          organization_role: organization_role(),
          project_role: project_role(),
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
  Assigns the active project on the scope.
  """
  @spec with_project(t(), %Project{}) :: t()
  def with_project(%__MODULE__{} = scope, %Project{} = project),
    do: %{scope | project: project}

  @doc """
  Assigns the organization role.
  """
  @spec with_organization_role(t(), organization_role()) :: t()
  def with_organization_role(%__MODULE__{} = scope, role) when role in @organization_roles,
    do: %{scope | organization_role: role}

  def with_organization_role(%__MODULE__{} = scope, nil), do: %{scope | organization_role: nil}

  @doc """
  Assigns the project role.
  """
  @spec with_project_role(t(), project_role()) :: t()
  def with_project_role(%__MODULE__{} = scope, role) when role in @project_roles,
    do: %{scope | project_role: role}

  def with_project_role(%__MODULE__{} = scope, nil), do: %{scope | project_role: nil}

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
  Whether scope has project admin privileges.
  """
  @spec project_admin?(t()) :: boolean()
  def project_admin?(%__MODULE__{project_role: :admin}), do: true
  def project_admin?(%__MODULE__{}), do: false
end
