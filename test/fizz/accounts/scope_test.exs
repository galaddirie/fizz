defmodule Fizz.Accounts.ScopeTest do
  use ExUnit.Case, async: true

  alias Fizz.Accounts.Workspace
  alias Fizz.Executions.Execution
  alias Fizz.Accounts.Scope
  alias Fizz.Workflows.Workflow

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

  test "can_view_workflow?/2 allows viewer/member/admin in same workspace" do
    scope = scope_for_workspace("workspace_123", :viewer)
    workflow = %Workflow{workspace_id: "workspace_123"}

    assert Scope.can_view_workflow?(scope, workflow)
  end

  test "can_edit_workflow?/2 allows member/admin in same workspace and denies viewer" do
    workflow = %Workflow{workspace_id: "workspace_123"}
    viewer_scope = scope_for_workspace("workspace_123", :viewer)
    member_scope = scope_for_workspace("workspace_123", :member)
    admin_scope = scope_for_workspace("workspace_123", :admin)

    refute Scope.can_edit_workflow?(viewer_scope, workflow)
    assert Scope.can_edit_workflow?(member_scope, workflow)
    assert Scope.can_edit_workflow?(admin_scope, workflow)
  end

  test "can_view_workflow?/2 and can_edit_workflow?/2 deny cross-workspace access" do
    scope = scope_for_workspace("workspace_abc", :admin)
    workflow = %Workflow{workspace_id: "workspace_xyz"}

    refute Scope.can_view_workflow?(scope, workflow)
    refute Scope.can_edit_workflow?(scope, workflow)
  end

  test "organization admins can edit workflows in the active workspace even without workspace role" do
    scope =
      %Scope{}
      |> Scope.with_workspace(%Workspace{id: "workspace_123"})
      |> Scope.with_organization_role(:owner)
      |> Map.put(:user, %{id: "user_123"})
      |> Map.put(:actor, :user)

    workflow = %Workflow{workspace_id: "workspace_123"}

    assert Scope.can_edit_workflow?(scope, workflow)
    assert Scope.can_view_workflow?(scope, workflow)
  end

  test "can_view_execution?/2 delegates to workflow access" do
    scope = scope_for_workspace("workspace_123", :viewer)
    execution = %Execution{workflow: %Workflow{workspace_id: "workspace_123"}}

    assert Scope.can_view_execution?(scope, execution)
  end

  test "can_create_execution?/3 allows nil scope only for production execution in scoped workflows" do
    scoped_workflow = %Workflow{workspace_id: "workspace_123"}

    assert Scope.can_create_execution?(nil, scoped_workflow, :production)
    refute Scope.can_create_execution?(nil, scoped_workflow, :preview)
  end

  defp scope_for_workspace(workspace_id, workspace_role) do
    %Scope{}
    |> Scope.with_workspace(%Workspace{
      id: workspace_id,
      name: "Workspace",
      slug: "workspace",
      workos_organization_id: "org_123"
    })
    |> Scope.with_workspace_role(workspace_role)
    |> Scope.with_organization_role(:member)
    |> Map.put(:user, %{id: "user_123"})
    |> Map.put(:actor, :user)
  end
end
