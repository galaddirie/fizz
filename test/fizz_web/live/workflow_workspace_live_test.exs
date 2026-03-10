defmodule FizzWeb.WorkflowWorkspaceLiveTest do
  use FizzWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fizz.Accounts.{Scope, Workspace, WorkspaceMembership}
  alias Fizz.Repo
  alias Fizz.Workflows

  defmodule WorkOSHTTPStub do
    def request(opts) do
      case {opts[:method], opts[:url]} do
        {:get, "/user_management/organization_memberships"} ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "data" => [
                 %{
                   "status" => "active",
                   "role" => %{"slug" => "owner"}
                 }
               ]
             }
           }}

        _ ->
          {:ok, %Req.Response{status: 200, body: %{}}}
      end
    end
  end

  setup %{conn: conn} do
    previous_http_client = Application.get_env(:fizz, :workos_http_client_module)
    previous_workos_client = Application.get_env(:workos, WorkOS.Client)

    Application.put_env(:fizz, :workos_http_client_module, WorkOSHTTPStub)

    Application.put_env(:workos, WorkOS.Client,
      api_key: "test_api_key",
      client_id: "test_client_id",
      client: Fizz.Accounts.WorkOS.ReqClient
    )

    on_exit(fn ->
      Application.put_env(:fizz, :workos_http_client_module, previous_http_client)

      case previous_workos_client do
        nil -> Application.delete_env(:workos, WorkOS.Client)
        value -> Application.put_env(:workos, WorkOS.Client, value)
      end
    end)

    user = Fizz.AccountsFixtures.user_fixture()
    workspace = workspace_fixture!(user)
    scope = scoped_workspace_access(user, workspace)
    conn = log_in_user(conn, user)

    %{conn: conn, workspace: workspace, scope: scope}
  end

  test "workflow index loads for authenticated workspace user", %{
    conn: conn,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/workflows")

    assert has_element?(view, "#workflows")
    assert has_element?(view, "#workflow-create-button")
  end

  test "workflow index creates a workflow and navigates to workflow show", %{
    conn: conn,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/workflows")

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> element("#workflow-create-button")
             |> render_click()

    assert to =~ ~r{^/workspaces/#{workspace.id}/workflows/[0-9a-f-]+$}
  end

  test "workflow show renders workflow details without execution history", %{
    conn: conn,
    workspace: workspace,
    scope: scope
  } do
    workflow = workflow_fixture!(scope)

    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}/workflows/#{workflow.id}")

    assert has_element?(view, "a[href='/workspaces/#{workspace.id}/workflows']")
    assert has_element?(view, "h2", "Workflow Details")
    refute has_element?(view, "h2", "Recent Executions")
  end

  defp workspace_fixture!(user) do
    unique = System.unique_integer([:positive])

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        name: "Workflow Workspace #{unique}",
        slug: "workflow-workspace-#{unique}",
        workos_organization_id: "org_#{unique}"
      })
      |> Repo.insert!()

    %WorkspaceMembership{workspace_id: workspace.id, user_id: user.id}
    |> WorkspaceMembership.changeset(%{role: :admin})
    |> Repo.insert!()

    workspace
  end

  defp scoped_workspace_access(user, workspace) do
    Scope.for_user(user)
    |> Scope.with_organization_id(workspace.workos_organization_id)
    |> Scope.with_organization_role(:owner)
    |> Scope.with_workspace(workspace)
    |> Scope.with_workspace_role(:admin)
  end

  defp workflow_fixture!(scope) do
    {:ok, workflow} =
      Workflows.create_workflow(scope, %{
        name: "Order Intake #{System.unique_integer([:positive])}",
        description: "Handles inbound events"
      })

    {:ok, _draft} =
      Workflows.update_workflow_draft(scope, workflow, %{
        steps: [],
        connections: [],
        groups: []
      })

    workflow
  end
end
