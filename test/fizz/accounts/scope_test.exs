defmodule Fizz.Accounts.ScopeTest do
  use ExUnit.Case, async: true

  alias Fizz.Accounts.Scope

  test "for_user/1 returns nil for anonymous user" do
    assert Scope.for_user(nil) == nil
  end

  test "tenant_admin?/1 checks owner and admin roles" do
    owner_scope = %Scope{} |> Scope.with_tenant_role(:owner)
    admin_scope = %Scope{} |> Scope.with_tenant_role(:admin)
    member_scope = %Scope{} |> Scope.with_tenant_role(:member)

    assert Scope.tenant_admin?(owner_scope)
    assert Scope.tenant_admin?(admin_scope)
    refute Scope.tenant_admin?(member_scope)
  end

  test "workspace_admin?/1 checks workspace admin role" do
    admin_scope = %Scope{} |> Scope.with_workspace_role(:admin)
    member_scope = %Scope{} |> Scope.with_workspace_role(:member)

    assert Scope.workspace_admin?(admin_scope)
    refute Scope.workspace_admin?(member_scope)
  end
end
