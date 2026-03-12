defmodule Fizz.Accounts.ScopeTest do
  use ExUnit.Case, async: true

  alias Fizz.Accounts.Scope

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
end
