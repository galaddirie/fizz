defmodule Fizz.Accounts.ScopeTest do
  use ExUnit.Case, async: true

  alias Fizz.Accounts.Scope
  alias Fizz.Accounts.{User, Workspace}

  test "for_user/1 returns nil for anonymous user" do
    assert Scope.for_user(nil) == nil
  end

  test "with_organization_id/2 stores the active WorkOS organization id" do
    scope = Scope.with_organization_id(%Scope{}, "org_123")
    assert scope.organization_id == "org_123"
  end

  test "organization_admin?/1 checks owner and admin roles" do
    owner_scope = %Scope{} |> Scope.with_organization_role(:owner)
    admin_scope = %Scope{} |> Scope.with_organization_role(:admin)
    member_scope = %Scope{} |> Scope.with_organization_role(:member)

    assert Scope.organization_admin?(owner_scope)
    assert Scope.organization_admin?(admin_scope)
    refute Scope.organization_admin?(member_scope)
  end

  test "workspace_admin?/1 checks workspace admin role" do
    admin_scope = %Scope{} |> Scope.with_workspace_role(:admin)
    member_scope = %Scope{} |> Scope.with_workspace_role(:member)

    assert Scope.workspace_admin?(admin_scope)
    refute Scope.workspace_admin?(member_scope)
  end

  test "user_id/1 and workspace_id/1 read identifiers from scope" do
    user_id = Ecto.UUID.generate()
    workspace_id = Ecto.UUID.generate()

    scope =
      Scope.for_user(%User{id: user_id})
      |> Scope.with_workspace(%Workspace{id: workspace_id, workos_organization_id: "org_123"})

    assert Scope.user_id(scope) == user_id
    assert Scope.workspace_id(scope) == workspace_id
  end

  test "public workflows can be viewed without persistence" do
    assert Scope.can_view_workflow?(nil, %{public: true})
    refute Scope.can_view_workflow?(nil, %{public: false})
  end

  test "preview execution creation requires edit access while production allows view access" do
    owner_id = Ecto.UUID.generate()
    viewer_id = Ecto.UUID.generate()
    viewer_scope = Scope.for_user(%User{id: viewer_id})

    workflow = %{user_id: owner_id, public: true}

    refute Scope.can_create_execution?(viewer_scope, workflow, :preview)
    assert Scope.can_create_execution?(viewer_scope, workflow, :production)
  end
end
