defmodule Fizz.Accounts.OrganizationIdentityTest do
  use Fizz.DataCase

  alias Fizz.Accounts
  alias Fizz.Accounts.{Scope, WorkspaceMembership}
  alias Fizz.Repo

  import Fizz.AccountsFixtures

  setup do
    previous_workos_client_module = Application.get_env(:fizz, :workos_client_module)
    mock_store = start_supervised!({Agent, fn -> %{} end})

    Fizz.WorkOSClientMock.configure(self(), mock_store)
    Application.put_env(:fizz, :workos_client_module, Fizz.WorkOSClientMock)

    on_exit(fn ->
      restore_env(:fizz, :workos_client_module, previous_workos_client_module)
      Fizz.WorkOSClientMock.reset()
    end)

    :ok
  end

  describe "organization/workspace primitives" do
    setup do
      user = user_fixture()

      owner_scope =
        Scope.for_user(user)
        |> Scope.with_organization_id("org_123")
        |> Scope.with_organization_role(:owner)

      %{user: user, owner_scope: owner_scope}
    end

    test "build_scope/3 resolves organization role from WorkOS memberships", %{user: user} do
      Fizz.WorkOSClientMock.put_response(:get_user_organization_membership, fn workos_user_id,
                                                                               organization_id ->
        assert workos_user_id == user.workos_user_id
        assert organization_id == "org_123"

        {:ok,
         %{
           "id" => "om_123",
           "organization_id" => "org_123",
           "status" => "active",
           "role" => %{"slug" => "admin"}
         }}
      end)

      assert {:ok, organization_scope} = Accounts.build_scope(Scope.for_user(user), "org_123")
      assert organization_scope.organization_id == "org_123"
      assert organization_scope.organization_role == :admin
      assert Scope.organization_admin?(organization_scope)
    end

    test "create_workspace/2 creates admin workspace membership for creator", %{
      owner_scope: owner_scope
    } do
      {:ok, workspace} = Accounts.create_workspace(owner_scope, %{name: "Client A"})

      assert workspace.workos_organization_id == "org_123"

      assert %WorkspaceMembership{role: :admin} =
               Repo.get_by(WorkspaceMembership,
                 workspace_id: workspace.id,
                 user_id: owner_scope.user.id
               )
    end

    test "list_workspaces/1 limits members to assigned workspaces", %{owner_scope: owner_scope} do
      {:ok, workspace_a} = Accounts.create_workspace(owner_scope, %{name: "Client A"})
      {:ok, _workspace_b} = Accounts.create_workspace(owner_scope, %{name: "Client B"})

      user = user_fixture()

      {:ok, _workspace_membership} =
        Accounts.add_workspace_member(owner_scope, workspace_a.id, user, %{role: :member})

      Fizz.WorkOSClientMock.put_response(
        :get_user_organization_membership,
        {:ok,
         %{
           "id" => "om_456",
           "organization_id" => "org_123",
           "status" => "active",
           "role" => %{"slug" => "member"}
         }}
      )

      {:ok, user_scope} = Accounts.build_scope(Scope.for_user(user), "org_123")
      {:ok, workspaces} = Accounts.list_workspaces(user_scope)

      assert Enum.map(workspaces, & &1.id) == [workspace_a.id]
    end

    test "organization members cannot manage organization membership", %{owner_scope: owner_scope} do
      target_user = user_fixture()

      member_scope =
        owner_scope
        |> Scope.with_organization_role(:member)

      assert {:error, :forbidden} =
               Accounts.add_organization_member(member_scope, target_user, %{role: :member})
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
