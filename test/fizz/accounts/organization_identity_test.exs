defmodule Fizz.Accounts.OrganizationIdentityTest do
  use Fizz.DataCase

  alias Fizz.Accounts
  alias Fizz.Accounts.{Scope, WorkspaceMembership}
  alias Fizz.Repo

  import Fizz.AccountsFixtures

  defmodule ReqMock do
    def request(opts) do
      send(self(), {:workos_http_request, opts})

      case Process.get(:workos_http_responses, []) do
        [response | rest] ->
          Process.put(:workos_http_responses, rest)
          response

        [] ->
          raise "No mocked WorkOS HTTP responses were configured"
      end
    end
  end

  setup do
    previous_http_client = Application.get_env(:fizz, :workos_http_client_module)
    previous_workos_client = Application.get_env(:workos, WorkOS.Client)

    Application.put_env(:fizz, :workos_http_client_module, ReqMock)

    Application.put_env(:workos, WorkOS.Client,
      api_key: "sk_test_123",
      client_id: "client_test_123",
      client: Fizz.WorkOS.ReqClient
    )

    on_exit(fn ->
      restore_env(:fizz, :workos_http_client_module, previous_http_client)
      restore_env(:workos, WorkOS.Client, previous_workos_client)
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
      Process.put(:workos_http_responses, [
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "data" => [
               %{
                 "id" => "om_123",
                 "organization_id" => "org_123",
                 "status" => "active",
                 "role" => %{"slug" => "admin"}
               }
             ]
           }
         }}
      ])

      assert {:ok, organization_scope} = Accounts.build_scope(Scope.for_user(user), "org_123")
      assert organization_scope.organization_id == "org_123"
      assert organization_scope.organization_role == :admin
      assert Scope.organization_admin?(organization_scope)

      assert_receive {:workos_http_request, request}
      assert request[:method] == :get
      assert request[:url] == "/user_management/organization_memberships"
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

    test "list_workspaces/1 limits members to assigned workspaces", %{
      owner_scope: owner_scope
    } do
      {:ok, workspace_a} = Accounts.create_workspace(owner_scope, %{name: "Client A"})
      {:ok, _workspace_b} = Accounts.create_workspace(owner_scope, %{name: "Client B"})

      user = user_fixture()

      {:ok, _workspace_membership} =
        Accounts.add_workspace_member(owner_scope, workspace_a.id, user, %{role: :member})

      Process.put(:workos_http_responses, [
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "data" => [
               %{
                 "id" => "om_456",
                 "organization_id" => "org_123",
                 "status" => "active",
                 "role" => %{"slug" => "member"}
               }
             ]
           }
         }}
      ])

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
