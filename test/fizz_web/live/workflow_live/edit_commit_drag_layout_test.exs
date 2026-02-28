defmodule FizzWeb.WorkflowLive.EditCommitDragLayoutTest do
  use FizzWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fizz.Accounts.{Scope, Workspace, WorkspaceMembership}
  alias Fizz.Collaboration.EditSession.Server
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
    workflow = workflow_fixture!(scope)
    conn = log_in_user(conn, user)

    %{conn: conn, user: user, workspace: workspace, scope: scope, workflow: workflow}
  end

  test "editor_command commit_drag_layout applies one coherent draft commit", %{
    conn: conn,
    workspace: workspace,
    workflow: workflow
  } do
    {:ok, view, _html} =
      live(conn, ~p"/workspaces/#{workspace.id}/workflows/#{workflow.id}/edit")

    payload = %{
      "txn_id" => "txn-liveview-1",
      "base_seq" => 0,
      "groups" => [
        %{
          "group_id" => "group_a",
          "position" => %{"x" => 130, "y" => 140, "width" => 430, "height" => 310}
        }
      ],
      "step_positions" => %{
        "step_a" => %{"x" => 45, "y" => 55},
        "step_b" => %{"x" => 200, "y" => 210}
      },
      "group_id_by_step_id" => %{
        "step_b" => nil
      }
    }

    render_hook(view, "editor_command", %{
      "type" => "commit_drag_layout",
      "payload" => payload
    })

    _ = :sys.get_state(view.pid)

    assert {:ok, %{type: :full_sync, draft: draft, seq: seq}} = Server.get_sync_state(workflow.id)
    assert seq > 0
    assert group_position_for(draft, "group_a") == %{x: 130, y: 140, width: 430, height: 310}
    assert step_position_for(draft, "step_a") == %{x: 45, y: 55}
    assert step_position_for(draft, "step_b") == %{x: 200, y: 210}
    assert group_step_ids_for(draft, "group_a") == ["step_a"]
  end

  defp group_position_for(draft, group_id) do
    draft.groups
    |> List.wrap()
    |> Enum.find(fn group -> Map.get(group, :id) == group_id end)
    |> Map.get(:position)
  end

  defp group_step_ids_for(draft, group_id) do
    draft.groups
    |> List.wrap()
    |> Enum.find(fn group -> Map.get(group, :id) == group_id end)
    |> Map.get(:step_ids)
  end

  defp step_position_for(draft, step_id) do
    draft.steps
    |> List.wrap()
    |> Enum.find(fn step -> Map.get(step, :id) == step_id end)
    |> Map.get(:position)
  end

  defp workspace_fixture!(user) do
    unique = System.unique_integer([:positive])

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        name: "LiveView Edit Workspace #{unique}",
        slug: "liveview-edit-workspace-#{unique}",
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
        name: "LiveView Commit Layout #{System.unique_integer([:positive])}",
        description: "liveview test"
      })

    {:ok, _draft} =
      Workflows.update_workflow_draft(scope, workflow, %{
        steps: [
          %{
            id: "step_a",
            type_id: "math",
            name: "Step A",
            config: %{},
            position: %{x: 60, y: 60}
          },
          %{
            id: "step_b",
            type_id: "math",
            name: "Step B",
            config: %{},
            position: %{x: 140, y: 110}
          }
        ],
        connections: [],
        groups: [
          %{
            id: "group_a",
            name: "Group A",
            step_ids: ["step_a", "step_b"],
            output_step_id: "step_a",
            position: %{x: 100, y: 100, width: 320, height: 240},
            color: nil,
            collapsed: false
          }
        ]
      })

    workflow
  end
end
