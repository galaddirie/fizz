defmodule FizzWeb.WorkflowEditorLiveTest do
  use FizzWeb.ConnCase, async: false

  import LiveVue.Test
  import Phoenix.LiveViewTest

  alias Fizz.Accounts.Scope
  alias Fizz.Workflows
  alias Fizz.Workflows.DraftSession
  alias FizzWeb.Presence

  defmodule ReqMock do
    def request(opts) do
      case {opts[:method], opts[:url]} do
        {:get, "/user_management/organization_memberships"} ->
          organization_id =
            Keyword.get(opts[:params] || [], :organization_id) ||
              get_in(opts, [:params, :organization_id]) ||
              "org_test"

          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "data" => [
                 %{
                   "id" => "om_#{System.unique_integer([:positive])}",
                   "organization_id" => organization_id,
                   "status" => "active",
                   "role" => %{"slug" => "owner"}
                 }
               ]
             }
           }}

        _ ->
          {:ok, %Req.Response{status: 404, body: %{"message" => "Not found"}}}
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
      client: Fizz.Accounts.WorkOS.ReqClient
    )

    on_exit(fn ->
      restore_env(:fizz, :workos_http_client_module, previous_http_client)
      restore_env(:workos, WorkOS.Client, previous_workos_client)
    end)

    :ok
  end

  test "mounting loads the definition and draft and renders the workflow editor", %{
    conn: conn
  } do
    %{conn: conn, definition: definition, draft: draft} = editor_fixture(conn)

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

    assert has_element?(view, "#workflow-editor")

    vue = get_vue(view, id: "workflow-editor")

    assert vue.component == "WorkflowEditor"
    assert vue.props["workflow"]["id"] == definition.id
    assert vue.props["workflow"]["name"] == definition.name
    assert vue.props["workflow"]["draft"]["id"] == draft.id
    assert vue.props["workflow"]["draft"]["workflow_id"] == definition.id
  end

  test "editor_command add_step applies an operation through DraftSession", %{conn: conn} do
    %{conn: conn, definition: definition, project_scope: project_scope, user: user} =
      editor_fixture(conn)

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "add_step",
      "payload" => %{
        "type_id" => "debug",
        "position" => %{"x" => 420, "y" => 180}
      }
    })

    assert {:ok, draft, 1, undo_state} =
             DraftSession.join(view_version_id(view), project_scope, user.id)

    assert length(draft.steps) == 1
    assert undo_state.canUndo
    assert undo_state.undoLabel == "Add Step"
  end

  test "undo and redo commands work through DraftSession", %{conn: conn} do
    %{conn: conn, definition: definition, project_scope: project_scope, user: user} =
      editor_fixture(conn)

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "add_step",
      "payload" => %{
        "type_id" => "debug",
        "position" => %{"x" => 100, "y" => 120}
      }
    })

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{"type" => "undo", "payload" => %{"count" => 1}})

    version_id = view_version_id(view)

    assert {:ok, draft_after_undo, 2, undo_state_after_undo} =
             DraftSession.join(version_id, project_scope, user.id)

    assert draft_after_undo.steps == []
    refute undo_state_after_undo.canUndo
    assert undo_state_after_undo.canRedo

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{"type" => "redo", "payload" => %{"count" => 1}})

    assert {:ok, draft_after_redo, 3, undo_state_after_redo} =
             DraftSession.join(version_id, project_scope, user.id)

    assert length(draft_after_redo.steps) == 1
    assert undo_state_after_redo.canUndo
    refute undo_state_after_redo.canRedo
  end

  test "presence is tracked on mount", %{conn: conn} do
    %{conn: conn, definition: definition, draft: draft, user: user} = editor_fixture(conn)
    user_id = user.id

    {:ok, _view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

    assert %{^user_id => %{metas: [meta | _]}} = Presence.list("draft:#{draft.id}")
    assert meta.user_id == user.id
    assert meta.user_email == user.email
    assert meta.selected_steps == []
  end

  test "unauthenticated users are redirected", %{conn: conn} do
    project_id = Ecto.UUID.generate()
    definition_id = Ecto.UUID.generate()

    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(conn, ~p"/projects/#{project_id}/workflows/#{definition_id}/edit")
  end

  defp editor_fixture(conn) do
    user = Fizz.AccountsFixtures.user_fixture()
    organization_scope = Fizz.AccountsFixtures.organization_scope_fixture(user: user)

    project =
      Fizz.AccountsFixtures.project_fixture(organization_scope, %{
        name: "Workflow Project #{System.unique_integer([:positive])}"
      })

    project_scope =
      organization_scope
      |> Scope.with_project(project)
      |> Scope.with_project_role(:admin)

    {:ok, %{definition: definition, draft: draft}} =
      Workflows.create_definition(project_scope, %{
        name: "Workflow #{System.unique_integer([:positive])}",
        description: "Editor LiveView"
      })

    %{
      conn: log_in_user(conn, user),
      user: user,
      project_scope: project_scope,
      definition: definition,
      draft: draft
    }
  end

  defp view_version_id(view) do
    vue = get_vue(view, id: "workflow-editor")
    vue.props["workflow"]["draft"]["id"]
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
