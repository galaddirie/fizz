defmodule Fizz.Accounts.OrganizationIdentityTest do
  use Fizz.DataCase

  alias Fizz.Accounts
  alias Fizz.Accounts.{OrganizationMembership, Scope, WorkspaceMembership}
  alias Fizz.Repo

  import Fizz.AccountsFixtures

  describe "organization primitives" do
    setup do
      user = user_fixture()
      user_scope = Scope.for_user(user)

      {:ok, organization} =
        Accounts.create_organization(user_scope, %{name: "Acme Agency"}, sync_workos: false)

      {:ok, organization_scope} = Accounts.build_scope(user_scope, organization.id)

      %{
        user: user,
        user_scope: user_scope,
        organization: organization,
        organization_scope: organization_scope
      }
    end

    test "create_organization/3 creates owner membership", %{
      user: user,
      organization: organization
    } do
      assert %OrganizationMembership{role: :owner} =
               Repo.get_by(OrganizationMembership,
                 organization_id: organization.id,
                 user_id: user.id
               )
    end

    test "build_scope/3 resolves organization role", %{
      organization: organization,
      organization_scope: organization_scope
    } do
      assert organization_scope.organization.id == organization.id
      assert organization_scope.organization_role == :owner
      assert Scope.organization_admin?(organization_scope)
    end

    test "create_workspace/2 creates admin workspace membership for creator", %{
      organization_scope: organization_scope
    } do
      {:ok, workspace} = Accounts.create_workspace(organization_scope, %{name: "Client A"})

      assert %WorkspaceMembership{role: :admin} =
               Repo.get_by(WorkspaceMembership,
                 workspace_id: workspace.id,
                 user_id: organization_scope.user.id
               )
    end

    test "list_workspaces/1 limits members to assigned workspaces", %{
      organization: organization,
      organization_scope: organization_scope
    } do
      {:ok, workspace_a} = Accounts.create_workspace(organization_scope, %{name: "Client A"})
      {:ok, _workspace_b} = Accounts.create_workspace(organization_scope, %{name: "Client B"})

      user = user_fixture()

      {:ok, _organization_membership} =
        Accounts.add_organization_member(organization_scope, user, %{role: :member})

      {:ok, _workspace_membership} =
        Accounts.add_workspace_member(organization_scope, workspace_a.id, user, %{role: :member})

      {:ok, user_scope} = Accounts.build_scope(Scope.for_user(user), organization.id)
      {:ok, workspaces} = Accounts.list_workspaces(user_scope)

      assert Enum.map(workspaces, & &1.id) == [workspace_a.id]
    end

    test "organization members cannot manage organization membership", %{
      organization: organization,
      organization_scope: organization_scope
    } do
      member_user = user_fixture()
      target_user = user_fixture()

      {:ok, _membership} =
        Accounts.add_organization_member(organization_scope, member_user, %{role: :member})

      {:ok, member_scope} = Accounts.build_scope(Scope.for_user(member_user), organization.id)

      assert {:error, :forbidden} =
               Accounts.add_organization_member(member_scope, target_user, %{role: :member})
    end
  end
end
