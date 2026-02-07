defmodule Fizz.Accounts.IdentityTest do
  use Fizz.DataCase

  alias Fizz.Accounts
  alias Fizz.Accounts.{Scope, TenantMembership, WorkspaceMembership}

  import Fizz.AccountsFixtures

  describe "identity primitives" do
    setup do
      user = user_fixture()
      user_scope = Scope.for_user(user)

      {:ok, tenant} =
        Accounts.create_tenant(user_scope, %{name: "Acme Agency"}, sync_workos: false)

      {:ok, tenant_scope} = Accounts.build_scope(user_scope, tenant.id)

      %{user: user, user_scope: user_scope, tenant: tenant, tenant_scope: tenant_scope}
    end

    test "create_tenant/3 creates owner membership", %{user: user, tenant: tenant} do
      assert %TenantMembership{role: :owner} =
               Repo.get_by(TenantMembership, tenant_id: tenant.id, user_id: user.id)
    end

    test "build_scope/3 resolves tenant role", %{tenant: tenant, tenant_scope: tenant_scope} do
      assert tenant_scope.tenant.id == tenant.id
      assert tenant_scope.tenant_role == :owner
      assert Scope.tenant_admin?(tenant_scope)
    end

    test "create_workspace/2 creates admin workspace membership for creator", %{
      tenant_scope: tenant_scope
    } do
      {:ok, workspace} = Accounts.create_workspace(tenant_scope, %{name: "Client A"})

      assert %WorkspaceMembership{role: :admin} =
               Repo.get_by(WorkspaceMembership,
                 workspace_id: workspace.id,
                 user_id: tenant_scope.user.id
               )
    end

    test "list_workspaces/1 limits members to assigned workspaces", %{
      tenant: tenant,
      tenant_scope: tenant_scope
    } do
      {:ok, workspace_a} = Accounts.create_workspace(tenant_scope, %{name: "Client A"})
      {:ok, _workspace_b} = Accounts.create_workspace(tenant_scope, %{name: "Client B"})

      user = user_fixture()

      {:ok, _tenant_membership} = Accounts.add_tenant_member(tenant_scope, user, %{role: :member})

      {:ok, _workspace_membership} =
        Accounts.add_workspace_member(tenant_scope, workspace_a.id, user, %{role: :member})

      {:ok, user_scope} = Accounts.build_scope(Scope.for_user(user), tenant.id)
      {:ok, workspaces} = Accounts.list_workspaces(user_scope)

      assert Enum.map(workspaces, & &1.id) == [workspace_a.id]
    end

    test "tenant members cannot manage tenant membership", %{
      tenant: tenant,
      tenant_scope: tenant_scope
    } do
      member_user = user_fixture()
      target_user = user_fixture()

      {:ok, _membership} = Accounts.add_tenant_member(tenant_scope, member_user, %{role: :member})

      {:ok, member_scope} = Accounts.build_scope(Scope.for_user(member_user), tenant.id)

      assert {:error, :forbidden} =
               Accounts.add_tenant_member(member_scope, target_user, %{role: :member})
    end
  end
end
