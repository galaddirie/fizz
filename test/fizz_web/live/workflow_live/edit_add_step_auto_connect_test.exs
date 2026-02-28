defmodule FizzWeb.WorkflowLive.EditAddStepAutoConnectTest do
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

    %{conn: conn, workspace: workspace, workflow: workflow}
  end

  test "add_step with source auto_connect links existing source to new step", %{
    conn: conn,
    workspace: workspace,
    workflow: workflow
  } do
    {:ok, view, _html} =
      live(conn, ~p"/workspaces/#{workspace.id}/workflows/#{workflow.id}/edit")

    initial_step_ids = MapSet.new(["source", "agent"])

    render_hook(view, "editor_command", %{
      "type" => "add_step",
      "payload" => %{
        "type_id" => "math",
        "position" => %{"x" => 320, "y" => 240},
        "auto_connect" => %{
          "source_step_id" => "source",
          "source_output" => "main"
        }
      }
    })

    _ = :sys.get_state(view.pid)

    assert {:ok, %{type: :full_sync, draft: draft}} = Server.get_sync_state(workflow.id)

    new_step_id = draft |> step_ids() |> find_new_step_id(initial_step_ids)
    assert is_binary(new_step_id)

    assert has_connection?(draft, fn conn ->
             connection_field(conn, :source_step_id) == "source" and
               connection_field(conn, :target_step_id) == new_step_id and
               connection_field(conn, :source_output) == "main" and
               connection_field(conn, :target_input) == "main"
           end)
  end

  test "add_step with target slot auto_connect links new subnode into target slot", %{
    conn: conn,
    workspace: workspace,
    workflow: workflow
  } do
    {:ok, view, _html} =
      live(conn, ~p"/workspaces/#{workspace.id}/workflows/#{workflow.id}/edit")

    initial_step_ids = MapSet.new(["source", "agent"])

    render_hook(view, "editor_command", %{
      "type" => "add_step",
      "payload" => %{
        "type_id" => "openai_model",
        "position" => %{"x" => 420, "y" => 180},
        "auto_connect" => %{
          "target_step_id" => "agent",
          "target_input" => "model"
        }
      }
    })

    _ = :sys.get_state(view.pid)

    assert {:ok, %{type: :full_sync, draft: draft}} = Server.get_sync_state(workflow.id)

    new_step_id = draft |> step_ids() |> find_new_step_id(initial_step_ids)
    assert is_binary(new_step_id)

    assert has_connection?(draft, fn conn ->
             connection_field(conn, :source_step_id) == new_step_id and
               connection_field(conn, :target_step_id) == "agent" and
               connection_field(conn, :source_output) == "main" and
               connection_field(conn, :target_input) == "model"
           end)
  end

  test "invalid slot auto_connect keeps new step and shows warning flash", %{
    conn: conn,
    workspace: workspace,
    workflow: workflow
  } do
    {:ok, view, _html} =
      live(conn, ~p"/workspaces/#{workspace.id}/workflows/#{workflow.id}/edit")

    initial_step_ids = MapSet.new(["source", "agent"])

    render_hook(view, "editor_command", %{
      "type" => "add_step",
      "payload" => %{
        "type_id" => "math",
        "position" => %{"x" => 480, "y" => 260},
        "auto_connect" => %{
          "target_step_id" => "agent",
          "target_input" => "model"
        }
      }
    })

    _ = :sys.get_state(view.pid)

    assert {:ok, %{type: :full_sync, draft: draft}} = Server.get_sync_state(workflow.id)

    new_step_id = draft |> step_ids() |> find_new_step_id(initial_step_ids)
    assert is_binary(new_step_id)

    refute has_connection?(draft, fn conn ->
             connection_field(conn, :source_step_id) == new_step_id and
               connection_field(conn, :target_step_id) == "agent" and
               connection_field(conn, :target_input) == "model"
           end)

    assert render(view) =~ "Step added but auto-connect failed"
  end

  defp step_ids(draft) do
    draft.steps
    |> List.wrap()
    |> Enum.map(fn step -> connection_field(step, :id) end)
    |> Enum.reject(&is_nil/1)
  end

  defp find_new_step_id(step_ids, initial_step_ids) do
    Enum.find(step_ids, fn step_id -> not MapSet.member?(initial_step_ids, step_id) end)
  end

  defp has_connection?(draft, predicate) do
    draft.connections
    |> List.wrap()
    |> Enum.any?(predicate)
  end

  defp connection_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp workspace_fixture!(user) do
    unique = System.unique_integer([:positive])

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        name: "LiveView Auto Connect Workspace #{unique}",
        slug: "liveview-auto-connect-workspace-#{unique}",
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
        name: "LiveView Auto Connect #{System.unique_integer([:positive])}",
        description: "auto connect test"
      })

    {:ok, _draft} =
      Workflows.update_workflow_draft(scope, workflow, %{
        steps: [
          %{
            id: "source",
            type_id: "math",
            name: "Source",
            config: %{},
            position: %{x: 80, y: 120}
          },
          %{
            id: "agent",
            type_id: "ai_agent",
            name: "Agent",
            config: %{},
            position: %{x: 280, y: 120}
          }
        ],
        connections: [],
        groups: []
      })

    workflow
  end
end
