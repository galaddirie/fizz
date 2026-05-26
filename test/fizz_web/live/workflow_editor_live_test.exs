defmodule FizzWeb.WorkflowEditorLiveTest do
  use FizzWeb.ConnCase, async: false

  import LiveVue.Test
  import Phoenix.LiveViewTest

  alias Fizz.Accounts
  alias Fizz.Accounts.{ApiCredential, Scope}
  alias Fizz.Workflows
  alias Fizz.Workflows.DraftSession
  alias Fizz.WorkflowsFixtures
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

        {:post, "/widgets/token"} ->
          {:ok, %Req.Response{status: 200, body: %{"token" => "widget_token_123"}}}

        _ ->
          {:ok, %Req.Response{status: 404, body: %{"message" => "Not found"}}}
      end
    end
  end

  setup do
    previous_http_client = Application.get_env(:fizz, :workos_http_client_module)
    previous_workos_client = Application.get_env(:workos, WorkOS.Client)
    previous_draft_session = Application.get_env(:fizz, DraftSession, [])

    Application.put_env(:fizz, :workos_http_client_module, ReqMock)

    Application.put_env(:fizz, DraftSession,
      persist_debounce_ms: 25,
      idle_timeout_ms: 75,
      persist_retry_base_ms: 25,
      persist_retry_max_ms: 50
    )

    Application.put_env(:workos, WorkOS.Client,
      api_key: "sk_test_123",
      client_id: "client_test_123",
      client: Fizz.Accounts.WorkOS.ReqClient
    )

    on_exit(fn ->
      restore_env(:fizz, :workos_http_client_module, previous_http_client)
      Application.put_env(:fizz, DraftSession, previous_draft_session)
      restore_env(:workos, WorkOS.Client, previous_workos_client)
    end)

    :ok
  end

  test "mounting loads the definition and draft and renders the workflow editor", %{
    conn: conn
  } do
    %{conn: conn, definition: definition, draft: draft} = editor_fixture(conn)

    {:ok, view, _html} = live_editor(conn, definition)

    assert has_element?(view, "#workflow-editor")

    vue = get_vue(view, id: "workflow-editor")

    assert vue.component == "WorkflowEditor"
    assert vue.props["workflow"]["id"] == definition.id
    assert vue.props["workflow"]["project_id"] == definition.project_id
    assert vue.props["workflow"]["name"] == definition.name
    assert vue.props["workflow"]["created_by_user_id"] == definition.created_by_user_id
    assert vue.props["workflow"]["draft"]["id"] == draft.id
    assert vue.props["workflow"]["draft"]["workflow_definition_id"] == definition.id
    assert vue.props["workflow"]["draft"]["version"] == draft.version
    assert vue.props["workflow"]["draft"]["status"] == "draft"
    assert vue.props["workflow"]["draft"]["step_groups"] == []
    assert vue.props["widgetToken"] == "widget_token_123"
    refute Map.has_key?(vue.props["workflow"], "current_version_tag")
    refute Map.has_key?(vue.props["workflow"], "public")
    refute Map.has_key?(vue.props["workflow"], "user_id")
    refute Map.has_key?(vue.props["workflow"]["draft"], "workflow_id")
    refute Map.has_key?(vue.props["workflow"]["draft"], "groups")
    refute Map.has_key?(vue.props["workflow"]["draft"], "triggers")
  end

  test "workflow editor props include draft steps and step groups from backend data", %{
    conn: conn
  } do
    entry_step =
      WorkflowsFixtures.step(%{
        name: "Fetch Orders",
        position: %{"x" => 140, "y" => 220}
      })

    grouped_step =
      WorkflowsFixtures.step(%{
        name: "Send Email",
        position: %{"x" => 360, "y" => 220}
      })

    step_group = %{
      id: Ecto.UUID.generate(),
      name: "Fulfillment",
      step_ids: [grouped_step.id],
      position: %{"x" => 300, "y" => 180, "width" => 420, "height" => 240},
      color: "#16A34A",
      font_size: 16,
      collapsed: false
    }

    snapshot_attrs =
      WorkflowsFixtures.snapshot_attrs(%{
        steps: [entry_step, grouped_step],
        connections: [
          WorkflowsFixtures.connection(%{
            source_step_id: entry_step.id,
            target_step_id: grouped_step.id
          })
        ],
        step_groups: [step_group],
        viewport: %{"x" => 32, "y" => 48, "zoom" => 1.2}
      })

    %{conn: conn, definition: definition} = editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} = live_editor(conn, definition)

    vue = get_vue(view, id: "workflow-editor")
    draft = vue.props["workflow"]["draft"]

    assert Enum.any?(draft["steps"], fn step ->
             step["id"] == entry_step.id and
               step["name"] == entry_step.name and
               step["position"] == entry_step.position
           end)

    assert Enum.any?(draft["steps"], fn step ->
             step["id"] == grouped_step.id and
               step["name"] == grouped_step.name and
               step["position"] == grouped_step.position
           end)

    assert draft["step_groups"] == [
             %{
               "id" => step_group.id,
               "name" => step_group.name,
               "step_ids" => step_group.step_ids,
               "position" => step_group.position,
               "color" => step_group.color,
               "font_size" => step_group.font_size,
               "collapsed" => step_group.collapsed
             }
           ]

    refute Map.has_key?(hd(draft["step_groups"]), "output_step_id")
  end

  test "navigate_revisions opens the dedicated revision viewer page", %{conn: conn} do
    %{conn: conn, definition: definition} = editor_fixture(conn)

    {:ok, view, _html} = live_editor(conn, definition)

    {:ok, revision_view, _html} =
      view
      |> element("#workflow-editor")
      |> render_hook("editor_command", %{"type" => "navigate_revisions"})
      |> follow_redirect(
        conn,
        ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit/revisions"
      )

    register_revision_cleanup(revision_view)

    assert has_element?(revision_view, "#workflow-revision-viewer")

    vue = get_vue(revision_view, id: "workflow-revision-viewer")

    assert vue.component == "RevisionViewer"
    assert vue.props["workflow"]["id"] == definition.id
    assert vue.props["revision"]["kind"] == "current"
    assert vue.props["revision"]["label"] == "Current draft"
  end

  test "revision viewer selects an undo preview via patch params", %{conn: conn} do
    %{conn: conn, definition: definition} = editor_fixture(conn)

    {:ok, editor_view, _html} = live_editor(conn, definition)

    editor_view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "add_step",
      "payload" => %{
        "type_id" => "debug",
        "position" => %{"x" => 420, "y" => 180}
      }
    })

    {:ok, revision_view, _html} = live_revisions(conn, definition)

    revision_view
    |> element("#workflow-revision-viewer")
    |> render_hook("select_revision", %{"kind" => "undo", "depth" => 1})

    path = assert_patch(revision_view)

    assert path =~
             ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit/revisions"

    assert path =~ "kind=undo"
    assert path =~ "depth=1"

    socket = live_socket(revision_view)

    assert socket.assigns.selected_revision["kind"] == "undo"
    assert socket.assigns.selected_revision["depth"] == 1
    assert socket.assigns.undo_stack != []
    assert socket.assigns.selected_draft.steps == []
  end

  test "revision viewer applies a published version back into the current draft", %{conn: conn} do
    entry_step =
      WorkflowsFixtures.step(%{
        name: "Published Step",
        position: %{"x" => 140, "y" => 220}
      })

    published_snapshot =
      WorkflowsFixtures.snapshot_attrs(%{
        steps: [entry_step],
        connections: [],
        step_groups: []
      })

    %{
      conn: conn,
      definition: definition,
      draft: draft,
      project_scope: project_scope
    } = editor_fixture(conn, published_snapshot)

    assert {:ok, published_version} = Workflows.publish_draft(project_scope, draft)

    {:ok, editor_view, _html} = live_editor(conn, definition)
    current_draft_id = view_version_id(editor_view)

    editor_view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "add_step",
      "payload" => %{
        "type_id" => "debug",
        "position" => %{"x" => 420, "y" => 180}
      }
    })

    {:ok, revision_view, _html} = live_revisions(conn, definition)

    revision_view
    |> element("#workflow-revision-viewer")
    |> render_hook("select_revision", %{"kind" => "version", "id" => published_version.id})

    path = assert_patch(revision_view)

    assert path =~
             ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit/revisions"

    assert path =~ "kind=version"
    assert path =~ "id=#{published_version.id}"

    socket = live_socket(revision_view)

    assert socket.assigns.selected_revision["kind"] == "version"
    assert socket.assigns.selected_revision["id"] == published_version.id
    assert socket.assigns.selected_draft.id == published_version.id

    {:ok, redirected_view, _html} =
      revision_view
      |> element("#workflow-revision-viewer")
      |> render_hook("apply_revision", %{})
      |> follow_redirect(
        conn,
        ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit"
      )

    register_editor_cleanup(redirected_view)

    assert has_element?(redirected_view, "#workflow-editor")

    assert :ok =
             wait_until(fn ->
               case Workflows.get_version(project_scope, current_draft_id) do
                 {:ok, persisted_draft} ->
                   Enum.map(persisted_draft.steps, & &1.name) == ["Published Step"] and
                     persisted_draft.connections == []

                 {:error, _reason} ->
                   false
               end
             end)
  end

  test "editor_command add_step applies an operation through DraftSession", %{conn: conn} do
    %{conn: conn, definition: definition, project_scope: project_scope, user: user} =
      editor_fixture(conn)

    {:ok, view, _html} = live_editor(conn, definition)

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "add_step",
      "payload" => %{
        "type_id" => "debug",
        "position" => %{"x" => 420, "y" => 180}
      }
    })

    assert {:ok, draft, 1, undo_state, _editor_state} =
             DraftSession.join(view_version_id(view), project_scope, user.id)

    assert length(draft.steps) == 1
    assert undo_state.canUndo
    assert undo_state.undoLabel == "Add Step"
  end

  test "commit_drag_layout acknowledgements include the drag transaction id", %{conn: conn} do
    moved_step =
      WorkflowsFixtures.step(%{
        name: "Fetch Orders",
        position: %{"x" => 140, "y" => 220}
      })

    snapshot_attrs =
      WorkflowsFixtures.snapshot_attrs(%{
        steps: [moved_step]
      })

    %{conn: conn, definition: definition} = editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} = live_editor(conn, definition)

    txn_id = "txn_drag_commit"

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "commit_drag_layout",
      "payload" => %{
        "txn_id" => txn_id,
        "base_seq" => 0,
        "groups" => [],
        "step_positions" => %{
          moved_step.id => %{"x" => 320, "y" => 260}
        },
        "group_id_by_step_id" => %{}
      }
    })

    assert_push_event(view, "workflow:operation_ack", %{
      type: "commit_drag_layout",
      seq: 1,
      txn_id: ^txn_id
    })

    updated_step = Enum.find(live_socket(view).assigns.draft.steps, &(&1.id == moved_step.id))

    assert updated_step.position["x"] == 320
    assert updated_step.position["y"] == 260
    assert live_socket(view).assigns.collab_seq == 1
  end

  test "draft changes autosave and update the save status indicator", %{conn: conn} do
    %{conn: conn, definition: definition, project_scope: project_scope} = editor_fixture(conn)

    {:ok, view, _html} = live_editor(conn, definition)

    initial_updated_at = live_socket(view).assigns.draft.updated_at

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "add_step",
      "payload" => %{
        "type_id" => "debug",
        "position" => %{"x" => 420, "y" => 180}
      }
    })

    assert live_socket(view).assigns.save_status == "saving"

    assert :ok =
             wait_until(fn ->
               render(view)

               with {:ok, persisted_draft} <-
                      Workflows.get_version(project_scope, view_version_id(view)) do
                 live_socket(view).assigns.save_status == "saved" and
                   length(persisted_draft.steps) == 1 and
                   persisted_draft.updated_at != initial_updated_at
               else
                 {:error, _reason} -> false
               end
             end)

    vue = get_vue(view, id: "workflow-editor")
    assert vue.props["saveStatus"] == "saved"
  end

  test "run_test persists the current draft before compiling", %{conn: conn} do
    %{conn: conn, definition: definition, project_scope: project_scope} = editor_fixture(conn)

    {:ok, view, _html} = live_editor(conn, definition)

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "add_step",
      "payload" => %{
        "type_id" => "debug",
        "position" => %{"x" => 420, "y" => 180}
      }
    })

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{"type" => "run_test", "payload" => %{}})

    assert {:ok, persisted_draft} = Workflows.get_version(project_scope, view_version_id(view))
    assert length(persisted_draft.steps) == 1
    assert live_socket(view).assigns.execution != nil

    assert {:ok, %{status: :completed}} =
             wait_for_run_status(
               project_scope,
               live_socket(view).assigns.execution.id,
               :completed
             )

    assert :ok = wait_for_worker_exit(live_socket(view).assigns.execution.id)
  end

  test "run_test starts a workflow run tagged with editor_test", %{conn: conn} do
    snapshot_attrs = WorkflowsFixtures.valid_snapshot_attrs()

    %{conn: conn, definition: definition, project_scope: project_scope, user: user} =
      editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} = live_editor(conn, definition)

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{"type" => "run_test", "payload" => %{}})

    execution = live_socket(view).assigns.execution

    assert execution.workflow_definition_id == definition.id
    assert execution.workflow_definition_version_id == view_version_id(view)
    assert execution.trigger.type == "editor_test"
    assert execution.triggered_by["kind"] == "editor_test"
    assert {:ok, run} = Workflows.get_run(project_scope, execution.id)
    assert run.triggered_by["kind"] == "editor_test"
    assert run.triggered_by["user_id"] == user.id

    assert {:ok, %{status: :completed}} =
             wait_for_run_status(project_scope, execution.id, :completed)

    assert :ok = wait_for_worker_exit(execution.id)
    GenServer.stop(view.pid, :normal)
  end

  test "run_test restores missing slot declarations before readiness", %{conn: conn} do
    append_step =
      WorkflowsFixtures.step(%{
        type_id: "google_sheets_append_row",
        name: "Append Row",
        config: %{
          "credential_ref" => nil,
          "spreadsheet_id" => "sheet_123",
          "values" => %{"A" => "1"}
        }
      })

    snapshot_attrs = WorkflowsFixtures.snapshot_attrs(%{steps: [append_step]})

    %{conn: conn, definition: definition, project_scope: project_scope} =
      editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} = live_editor(conn, definition)
    assert {:ok, runs_before} = Workflows.list_runs(project_scope, definition_id: definition.id)

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{"type" => "run_test", "payload" => %{}})

    assert_push_event(view, "slot_bindings_needed", %{
      descriptors: [
        %{
          kind: "credential",
          step_id: step_id,
          slot_key: "auth",
          spec: %{"provider" => "google_oauth", "auth_type" => "oauth"}
        }
      ]
    })

    assert step_id == append_step.id
    assert live_socket(view).assigns.execution == nil
    assert live_socket(view).assigns.validation_errors == %{}

    assert {:ok, runs_after} = Workflows.list_runs(project_scope, definition_id: definition.id)
    assert runs_after == runs_before
  end

  test "run_test uses saved manual trigger test data as workflow input", %{conn: conn} do
    trigger_step =
      WorkflowsFixtures.step(%{
        type_id: "manual_input",
        name: "Manual Trigger",
        config: %{
          "input_schema" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"},
              "email" => %{"type" => "string"}
            }
          },
          "test_data" => %{
            "name" => "Ada Lovelace",
            "email" => "ada@example.com"
          }
        }
      })

    debug_step = WorkflowsFixtures.step(%{type_id: "debug", name: "Debug"})

    snapshot_attrs =
      WorkflowsFixtures.snapshot_attrs(%{
        steps: [trigger_step, debug_step],
        connections: [
          WorkflowsFixtures.connection(%{
            source_step_id: trigger_step.id,
            target_step_id: debug_step.id
          })
        ]
      })

    %{conn: conn, definition: definition, project_scope: project_scope} =
      editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} = live_editor(conn, definition)

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{"type" => "run_test", "payload" => %{}})

    execution = live_socket(view).assigns.execution

    assert execution.input == %{
             "name" => "Ada Lovelace",
             "email" => "ada@example.com"
           }

    assert execution.triggered_by["trigger_step_id"] == trigger_step.id
    assert {:ok, run} = Workflows.get_run(project_scope, execution.id)

    assert run.input == %{
             "name" => "Ada Lovelace",
             "email" => "ada@example.com"
           }

    assert {:ok, %{status: :completed}} =
             wait_for_run_status(project_scope, execution.id, :completed)

    assert :ok = wait_for_worker_exit(execution.id)
    GenServer.stop(view.pid, :normal)
  end

  test "run_node starts a partial run and excludes downstream steps", %{conn: conn} do
    trigger_step =
      WorkflowsFixtures.step(%{
        type_id: "manual_input",
        name: "Manual Trigger",
        config: %{
          "test_data" => %{"ticket_id" => "T-42"}
        }
      })

    target_step = WorkflowsFixtures.step(%{type_id: "debug", name: "Target"})
    downstream_step = WorkflowsFixtures.step(%{type_id: "debug", name: "Downstream"})

    snapshot_attrs =
      WorkflowsFixtures.snapshot_attrs(%{
        steps: [trigger_step, target_step, downstream_step],
        connections: [
          WorkflowsFixtures.connection(%{
            source_step_id: trigger_step.id,
            target_step_id: target_step.id
          }),
          WorkflowsFixtures.connection(%{
            source_step_id: target_step.id,
            target_step_id: downstream_step.id
          })
        ]
      })

    %{conn: conn, definition: definition, project_scope: project_scope} =
      editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} = live_editor(conn, definition)

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "run_node",
      "payload" => %{"step_id" => target_step.id}
    })

    execution = live_socket(view).assigns.execution

    assert execution.input == %{"ticket_id" => "T-42"}
    assert execution.triggered_by["mode"] == "partial"
    assert execution.triggered_by["target_step_id"] == target_step.id

    assert {:ok, run} = Workflows.get_run(project_scope, execution.id)
    assert run.input == %{"ticket_id" => "T-42"}
    assert run.triggered_by["mode"] == "partial"
    assert run.triggered_by["target_step_id"] == target_step.id

    assert {:ok, %{status: :completed}} =
             wait_for_run_status(project_scope, execution.id, :completed)

    assert :ok =
             wait_until(fn ->
               render(view)

               step_ids =
                 live_socket(view).assigns.step_executions
                 |> Enum.map(& &1.step_id)
                 |> Enum.uniq()

               Enum.sort(step_ids) == Enum.sort([trigger_step.id, target_step.id])
             end)

    refute Enum.any?(
             live_socket(view).assigns.step_executions,
             &(&1.step_id == downstream_step.id)
           )

    assert :ok = wait_for_worker_exit(execution.id)
    GenServer.stop(view.pid, :normal)
  end

  test "publish_workflow persists before validation and blocks on validation errors", %{
    conn: conn
  } do
    %{conn: conn, definition: definition, project_scope: project_scope} = editor_fixture(conn)

    {:ok, view, _html} = live_editor(conn, definition)

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "add_step",
      "payload" => %{
        "type_id" => "http_request",
        "position" => %{"x" => 240, "y" => 180}
      }
    })

    version_id = view_version_id(view)

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "publish_workflow",
      "payload" => %{}
    })

    assert_push_event(view, "workflow:publish_result", %{
      success: false,
      validation_errors: errors,
      execution_hash_changed: execution_hash_changed
    })

    assert Enum.any?(errors, fn error ->
             code = Map.get(error, :code) || Map.get(error, "code")
             field = Map.get(error, :field) || Map.get(error, "field")

             code == "missing_required_field" and field == "url"
           end)

    assert execution_hash_changed in [true, false, nil]

    assert {:ok, persisted_draft} = Workflows.get_version(project_scope, version_id)
    assert length(persisted_draft.steps) == 1
    assert persisted_draft.status == :draft
    assert persisted_draft.published_at == nil
  end

  test "validate_draft returns publish preview results for the publish modal", %{conn: conn} do
    %{conn: conn, definition: definition} = editor_fixture(conn)

    {:ok, view, _html} = live_editor(conn, definition)

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "add_step",
      "payload" => %{
        "type_id" => "http_request",
        "position" => %{"x" => 240, "y" => 180}
      }
    })

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{"type" => "validate_draft", "payload" => %{}})

    assert_push_event(view, "workflow:validation_result", %{
      valid: false,
      validation_errors: errors,
      execution_hash_changed: execution_hash_changed
    })

    assert Enum.any?(errors, fn error ->
             code = Map.get(error, :code) || Map.get(error, "code")
             field = Map.get(error, :field) || Map.get(error, "field")

             code == "missing_required_field" and field == "url"
           end)

    assert execution_hash_changed in [true, false, nil]
  end

  test "publish_workflow publishes a valid draft", %{conn: conn} do
    snapshot_attrs = WorkflowsFixtures.valid_snapshot_attrs()

    %{conn: conn, definition: definition, project_scope: project_scope} =
      editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} = live_editor(conn, definition)

    version_id = view_version_id(view)

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "publish_workflow",
      "payload" => %{}
    })

    assert {:ok, published_version} = Workflows.get_version(project_scope, version_id)
    assert published_version.status == :published
    assert %DateTime{} = published_version.published_at
  end

  test "undo and redo commands work through DraftSession", %{conn: conn} do
    %{conn: conn, definition: definition, project_scope: project_scope, user: user} =
      editor_fixture(conn)

    {:ok, view, _html} = live_editor(conn, definition)

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

    assert {:ok, draft_after_undo, 2, undo_state_after_undo, _editor_state} =
             DraftSession.join(version_id, project_scope, user.id)

    assert draft_after_undo.steps == []
    refute undo_state_after_undo.canUndo
    assert undo_state_after_undo.canRedo

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{"type" => "redo", "payload" => %{"count" => 1}})

    assert {:ok, draft_after_redo, 3, undo_state_after_redo, _editor_state} =
             DraftSession.join(version_id, project_scope, user.id)

    assert length(draft_after_redo.steps) == 1
    assert undo_state_after_redo.canUndo
    refute undo_state_after_redo.canRedo
  end

  test "presence is tracked on mount", %{conn: conn} do
    %{conn: conn, definition: definition, draft: draft, user: user} = editor_fixture(conn)
    user_id = user.id

    {:ok, _view, _html} = live_editor(conn, definition)

    assert %{^user_id => %{metas: [meta | _]}} = Presence.list("draft:#{draft.id}")
    assert meta.user_id == user.id
    assert meta.user_email == user.email
    assert meta.selected_steps == []
  end

  test "cursor presence updates propagate to collaborators and clear on leave", %{conn: conn} do
    %{conn: owner_conn, definition: definition, project_scope: project_scope, user: owner_user} =
      editor_fixture(conn)

    owner_user_id = owner_user.id

    %{conn: collaborator_conn, user: collaborator_user} =
      collaborator_fixture(project_scope)

    {:ok, owner_view, _html} =
      live(owner_conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

    {:ok, collaborator_view, _html} =
      live(
        collaborator_conn,
        ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit"
      )

    draft_topic = "draft:#{view_version_id(owner_view)}"

    owner_view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "mouse_move",
      "payload" => %{"x" => 128, "y" => 256}
    })

    assert :ok =
             wait_until(fn ->
               case Presence.list(draft_topic) do
                 %{^owner_user_id => %{metas: [meta | _rest]}} ->
                   meta.cursor == %{x: 128, y: 256}

                 _other ->
                   false
               end
             end)

    send(
      collaborator_view.pid,
      %Phoenix.Socket.Broadcast{event: "presence_diff", topic: draft_topic, payload: %{}}
    )

    render(collaborator_view)

    assert %{cursor: %{x: 128, y: 256}} = collaborator_presence(collaborator_view, owner_user_id)

    owner_view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{"type" => "mouse_leave", "payload" => %{}})

    assert :ok =
             wait_until(fn ->
               case Presence.list(draft_topic) do
                 %{^owner_user_id => %{metas: [meta | _rest]}} ->
                   is_nil(meta.cursor)

                 _other ->
                   false
               end
             end)

    send(
      collaborator_view.pid,
      %Phoenix.Socket.Broadcast{event: "presence_diff", topic: draft_topic, payload: %{}}
    )

    render(collaborator_view)

    assert %{cursor: nil} = collaborator_presence(collaborator_view, owner_user_id)

    assert live_socket(collaborator_view).assigns.current_user_id == collaborator_user.id
  end

  test "unauthenticated users are redirected", %{conn: conn} do
    project_id = Ecto.UUID.generate()
    definition_id = Ecto.UUID.generate()

    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(conn, ~p"/projects/#{project_id}/workflows/#{definition_id}/edit")
  end

  test "preview_expression renders against pinned upstream output", %{conn: conn} do
    source_step = WorkflowsFixtures.step(%{name: "Fetch Orders"})
    target_step = WorkflowsFixtures.step(%{name: "Send Email"})

    snapshot_attrs =
      WorkflowsFixtures.snapshot_attrs(%{
        steps: [source_step, target_step],
        connections: [
          WorkflowsFixtures.connection(%{
            source_step_id: source_step.id,
            target_step_id: target_step.id
          })
        ]
      })

    %{conn: conn, definition: definition} = editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} = live_editor(conn, definition)

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "pin_output",
      "payload" => %{
        "step_id" => source_step.id,
        "output_data" => %{"name" => "Alice"}
      }
    })

    expression = "Hello {{ steps.#{source_step.id}.name }}"
    preview_expression(view, target_step.id, "text", expression)

    assert preview_value(view, preview_key(target_step.id, "text")) == "Hello Alice"
  end

  test "preview_expression returns parse errors for invalid expressions", %{conn: conn} do
    source_step = WorkflowsFixtures.step(%{name: "Fetch Orders"})
    target_step = WorkflowsFixtures.step(%{name: "Send Email"})

    snapshot_attrs =
      WorkflowsFixtures.snapshot_attrs(%{
        steps: [source_step, target_step],
        connections: [
          WorkflowsFixtures.connection(%{
            source_step_id: source_step.id,
            target_step_id: target_step.id
          })
        ]
      })

    %{conn: conn, definition: definition} = editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} = live_editor(conn, definition)

    expression = "{% if steps.#{source_step.id}.name %}"
    preview_expression(view, target_step.id, "text", expression)

    preview = preview_value(view, preview_key(target_step.id, "text"))

    assert preview.type == "parse_error"
    assert is_list(preview.errors)
    assert preview.errors != []
  end

  test "preview context prefers pinned outputs over execution outputs", %{conn: conn} do
    source_step = WorkflowsFixtures.step(%{name: "Fetch Orders"})
    target_step = WorkflowsFixtures.step(%{name: "Send Email"})

    snapshot_attrs =
      WorkflowsFixtures.snapshot_attrs(%{
        steps: [source_step, target_step],
        connections: [
          WorkflowsFixtures.connection(%{
            source_step_id: source_step.id,
            target_step_id: target_step.id
          })
        ]
      })

    %{conn: conn, definition: definition} = editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} = live_editor(conn, definition)

    put_step_executions(view, [
      %{
        "step_id" => source_step.id,
        "output_data" => %{"name" => "Execution"},
        "inserted_at" => "2026-03-20T10:00:00Z"
      }
    ])

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "pin_output",
      "payload" => %{
        "step_id" => source_step.id,
        "output_data" => %{"name" => "Pinned"}
      }
    })

    expression = "Hello {{ steps.#{source_step.id}.name }}"
    preview_expression(view, target_step.id, "text", expression)

    assert preview_value(view, preview_key(target_step.id, "text")) == "Hello Pinned"
  end

  test "preview_expression debounces repeated requests for the same field", %{conn: conn} do
    source_step = WorkflowsFixtures.step(%{name: "Fetch Orders"})
    target_step = WorkflowsFixtures.step(%{name: "Send Email"})

    snapshot_attrs =
      WorkflowsFixtures.snapshot_attrs(%{
        steps: [source_step, target_step],
        connections: [
          WorkflowsFixtures.connection(%{
            source_step_id: source_step.id,
            target_step_id: target_step.id
          })
        ]
      })

    %{conn: conn, definition: definition} = editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} = live_editor(conn, definition)

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "pin_output",
      "payload" => %{
        "step_id" => source_step.id,
        "output_data" => %{"name" => "Alice"}
      }
    })

    key = preview_key(target_step.id, "text")
    first_expression = "Hello {{ steps.#{source_step.id}.name }}"
    second_expression = "Goodbye {{ steps.#{source_step.id}.name }}"

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "preview_expression",
      "payload" => %{
        "step_id" => target_step.id,
        "field_key" => "text",
        "expression" => first_expression
      }
    })

    first_ref = preview_timer_ref(view, key)

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "preview_expression",
      "payload" => %{
        "step_id" => target_step.id,
        "field_key" => "text",
        "expression" => second_expression
      }
    })

    second_ref = preview_timer_ref(view, key)

    refute first_ref == second_ref

    send(view.pid, {:preview_expression, key, target_step.id, first_expression, first_ref})
    render(view)

    refute Map.has_key?(expression_previews(view), key)

    send(view.pid, {:preview_expression, key, target_step.id, second_expression, second_ref})
    render(view)

    assert preview_value(view, key) == "Goodbye Alice"
  end

  test "step execution events update step_executions assigns", %{conn: conn} do
    step = WorkflowsFixtures.step(%{type_id: "debug", name: "Debug"})
    step_id = step.id
    snapshot_attrs = WorkflowsFixtures.snapshot_attrs(%{steps: [step]})

    %{conn: conn, definition: definition} = editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} = live_editor(conn, definition)

    put_execution(view, %{id: "run-live", status: "running"})

    started_at = DateTime.utc_now()

    send(
      view.pid,
      {:step_started,
       %{
         run_id: "run-live",
         runnable_id: 123,
         step_id: step_id,
         attempt: 0,
         input: %{"name" => "Ada"},
         input_fact_hash: "input-hash",
         started_at: started_at
       }}
    )

    render(view)

    assert [
             %{
               id: "run-live:123:0",
               step_id: ^step_id,
               status: "running",
               step_type_id: "debug",
               input_data: %{"name" => "Ada"}
             }
           ] =
             live_socket(view).assigns.step_executions

    completed_at = DateTime.utc_now()

    send(
      view.pid,
      {:step_completed,
       %{
         run_id: "run-live",
         runnable_id: 123,
         step_id: step_id,
         attempt: 0,
         input: %{"name" => "Ada"},
         input_fact_hash: "input-hash",
         output: %{"ok" => true},
         output_fact_hash: "output-hash",
         output_summary: "%{\"ok\" => true}",
         duration_us: 12_000,
         completed_at: completed_at
       }}
    )

    render(view)

    assert [
             %{
               id: "run-live:123:0",
               status: "completed",
               output_data: %{"ok" => true},
               output_item_count: 1,
               duration_us: 12_000
             }
           ] =
             live_socket(view).assigns.step_executions
  end

  test "terminal status unsubscribes from the run topic", %{conn: conn} do
    snapshot_attrs = WorkflowsFixtures.long_running_snapshot_attrs(5_000)

    %{conn: conn, definition: definition, project_scope: project_scope} =
      editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} = live_editor(conn, definition)

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{"type" => "run_test", "payload" => %{}})

    execution_id = live_socket(view).assigns.execution.id

    send(
      view.pid,
      {:run_status_changed,
       %{run_id: execution_id, status: :completed, timestamp: DateTime.utc_now()}}
    )

    render(view)

    Phoenix.PubSub.broadcast(
      Fizz.PubSub,
      "workflow_run:#{execution_id}",
      {:step_started,
       %{
         run_id: execution_id,
         runnable_id: 999,
         step_id: hd(Enum.map(snapshot_attrs.steps, & &1.id)),
         attempt: 0,
         started_at: DateTime.utc_now()
       }}
    )

    _ = :sys.get_state(view.pid)

    refute Enum.any?(
             live_socket(view).assigns.step_executions,
             &(&1.id == "#{execution_id}:999:0")
           )

    _ = Workflows.cancel_run(project_scope, execution_id)
    assert :ok = wait_for_worker_exit(execution_id)
  end

  test "cancel_execution stops the active run", %{conn: conn} do
    snapshot_attrs = WorkflowsFixtures.long_running_snapshot_attrs(5_000)

    %{conn: conn, definition: definition, project_scope: project_scope} =
      editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} = live_editor(conn, definition)

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{"type" => "run_test", "payload" => %{}})

    execution_id = live_socket(view).assigns.execution.id

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{"type" => "cancel_execution", "payload" => %{}})

    assert {:ok, %{status: :cancelled}} =
             wait_for_run_status(project_scope, execution_id, :cancelled)

    assert :ok = wait_for_worker_exit(execution_id)
  end

  test "step_cancelled event updates step execution status", %{conn: conn} do
    snapshot_attrs = WorkflowsFixtures.valid_snapshot_attrs()
    step_id = hd(Enum.map(snapshot_attrs.steps, & &1.id))
    run_id = Ecto.UUID.generate()

    %{conn: conn, definition: definition} = editor_fixture(conn, snapshot_attrs)
    {:ok, view, _html} = live_editor(conn, definition)

    put_execution(view, %{id: run_id, status: "running"})

    send(
      view.pid,
      {:step_started,
       %{
         run_id: run_id,
         runnable_id: 123,
         step_id: step_id,
         attempt: 0,
         input: %{"x" => 1},
         input_fact_hash: "hash",
         started_at: DateTime.utc_now()
       }}
    )

    render(view)
    assert [%{status: "running"}] = live_socket(view).assigns.step_executions

    send(
      view.pid,
      {:step_cancelled,
       %{
         run_id: run_id,
         runnable_id: 123,
         step_id: step_id,
         cancelled_at: DateTime.utc_now()
       }}
    )

    render(view)
    assert [%{status: "cancelled"}] = live_socket(view).assigns.step_executions
  end

  test "terminal run status marks running steps as cancelled", %{conn: conn} do
    snapshot_attrs = WorkflowsFixtures.valid_snapshot_attrs()
    steps = snapshot_attrs.steps
    step_a_id = Enum.at(steps, 0).id
    step_b_id = Enum.at(steps, 1).id
    run_id = Ecto.UUID.generate()

    %{conn: conn, definition: definition} = editor_fixture(conn, snapshot_attrs)
    {:ok, view, _html} = live_editor(conn, definition)

    put_execution(view, %{id: run_id, status: "running"})

    for {step_id, runnable_id} <- [{step_a_id, 1}, {step_b_id, 2}] do
      send(
        view.pid,
        {:step_started,
         %{
           run_id: run_id,
           runnable_id: runnable_id,
           step_id: step_id,
           attempt: 0,
           input: %{},
           input_fact_hash: "h",
           started_at: DateTime.utc_now()
         }}
      )
    end

    render(view)
    assert length(live_socket(view).assigns.step_executions) == 2
    assert Enum.all?(live_socket(view).assigns.step_executions, &(&1.status == "running"))

    send(
      view.pid,
      {:run_status_changed,
       %{
         run_id: run_id,
         status: :failed,
         timestamp: DateTime.utc_now()
       }}
    )

    render(view)

    statuses =
      live_socket(view).assigns.step_executions
      |> Enum.map(& &1.status)
      |> Enum.sort()

    assert statuses == ["cancelled", "cancelled"]
  end

  test "paused execution assigns correct status for stop button visibility", %{conn: conn} do
    snapshot_attrs = WorkflowsFixtures.long_running_snapshot_attrs(5_000)
    run_id = Ecto.UUID.generate()

    %{conn: conn, definition: definition} = editor_fixture(conn, snapshot_attrs)
    {:ok, view, _html} = live_editor(conn, definition)

    put_execution(view, %{id: run_id, status: "paused"})

    render(view)

    execution = live_socket(view).assigns.execution
    assert execution.status == "paused"
  end

  test "compilation errors are pushed to the client", %{conn: conn} do
    source_step = WorkflowsFixtures.step(%{type_id: "debug", name: "Source"})
    trigger_step = WorkflowsFixtures.step(%{type_id: "schedule_trigger", name: "Schedule"})

    snapshot_attrs =
      WorkflowsFixtures.snapshot_attrs(%{
        steps: [source_step, trigger_step],
        connections: [
          WorkflowsFixtures.connection(%{
            source_step_id: source_step.id,
            target_step_id: trigger_step.id
          })
        ]
      })

    %{conn: conn, definition: definition} = editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} = live_editor(conn, definition)

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{"type" => "run_test", "payload" => %{}})

    errors =
      live_socket(view).assigns.validation_errors
      |> Map.values()
      |> List.flatten()

    assert Enum.any?(errors, fn error ->
             error.code == :trigger_not_root and
               error.message =~ "trigger steps must be graph roots with no incoming connections"
           end)

    assert live_socket(view).assigns.execution == nil
    assert live_socket(view).assigns.validation_errors != %{}
  end

  test "resolve_field_options replies with credential options and pushes credential results", %{
    conn: conn
  } do
    model_step = WorkflowsFixtures.step(%{type_id: "openai_model", name: "Model"})
    model_step_id = model_step.id
    snapshot_attrs = WorkflowsFixtures.snapshot_attrs(%{steps: [model_step]})

    %{conn: conn, definition: definition, user: user, project_scope: project_scope} =
      editor_fixture(conn, snapshot_attrs)

    insert_api_credential!(
      user.id,
      project_scope.organization_id,
      "openai_api_key",
      "OpenAI Production"
    )

    {:ok, view, _html} = live_editor(conn, definition)

    render_hook(view, "resolve_field_options", %{
      "node_id" => model_step_id,
      "field_key" => "credential_ref",
      "q" => "production"
    })

    assert_reply(view, %{options: [%{"display_name" => "OpenAI Production"}]})

    assert_push_event(view, "credential_results", %{
      node_id: ^model_step_id,
      field_key: "credential_ref",
      q: "production",
      options: [%{"display_name" => "OpenAI Production"}]
    })
  end

  test "resolve_field_options replies with resource mapper metadata", %{conn: conn} do
    append_step =
      WorkflowsFixtures.step(%{type_id: "google_sheets_append_row", name: "Append Row"})

    snapshot_attrs = WorkflowsFixtures.snapshot_attrs(%{steps: [append_step]})

    %{conn: conn, definition: definition} = editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} = live_editor(conn, definition)

    render_hook(view, "resolve_field_options", %{
      "node_id" => append_step.id,
      "field_key" => "values",
      "params" => %{"mode" => "sheets"}
    })

    assert_reply(view, %{
      options: [],
      meta: %{
        depends_on: depends_on,
        resource_mapper: %{
          "kind" => "google_sheets.row_values",
          "lookups" => %{
            "primary_resource" => %{"mode" => "sheets"},
            "schema_resource" => %{"mode" => "tables"}
          }
        }
      }
    })

    assert "credential_ref" in depends_on
    assert "spreadsheet_id" in depends_on
  end

  defp editor_fixture(conn, snapshot_attrs \\ nil) do
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

    {:ok, %{definition: definition, draft: initial_draft}} =
      Workflows.create_definition(project_scope, %{
        name: "Workflow #{System.unique_integer([:positive])}",
        description: "Editor LiveView"
      })

    draft =
      case snapshot_attrs do
        nil ->
          initial_draft

        attrs ->
          {:ok, saved_draft} = Workflows.save_draft(project_scope, initial_draft, attrs)
          saved_draft
      end

    %{
      conn: log_in_user(conn, user),
      user: user,
      project_scope: project_scope,
      definition: definition,
      draft: draft
    }
  end

  defp collaborator_fixture(project_scope) do
    user = Fizz.AccountsFixtures.user_fixture()

    organization_scope =
      Fizz.AccountsFixtures.organization_scope_fixture(
        user: user,
        organization_id: project_scope.organization_id,
        organization_role: :member
      )

    {:ok, _membership} =
      Accounts.add_project_member(project_scope, project_scope.project.id, user, %{role: :member})

    collaborator_scope =
      organization_scope
      |> Scope.with_project(project_scope.project)
      |> Scope.with_project_role(:member)

    %{
      conn: log_in_user(build_conn(), user),
      user: user,
      project_scope: collaborator_scope
    }
  end

  defp live_editor(conn, definition) do
    {:ok, view, html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

    register_editor_cleanup(view)
    {:ok, view, html}
  end

  defp live_revisions(conn, definition) do
    {:ok, view, html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit/revisions")

    register_revision_cleanup(view)
    {:ok, view, html}
  end

  defp register_editor_cleanup(view) do
    version_id = view_version_id(view)

    on_exit(fn ->
      stop_draft_session(version_id)
    end)
  end

  defp register_revision_cleanup(view) do
    version_id = revision_view_version_id(view)

    on_exit(fn ->
      stop_draft_session(version_id)
    end)
  end

  defp view_version_id(view) do
    vue = get_vue(view, id: "workflow-editor")
    vue.props["workflow"]["draft"]["id"]
  end

  defp revision_view_version_id(view) do
    vue = get_vue(view, id: "workflow-revision-viewer")
    vue.props["workflow"]["draft"]["id"]
  end

  defp stop_draft_session(version_id) do
    case Registry.lookup(Fizz.Workflows.DraftSessionRegistry, version_id) do
      [{pid, _value}] ->
        try do
          GenServer.stop(pid, :normal)
        catch
          :exit, _reason -> :ok
        end

      [] ->
        :ok
    end
  end

  defp preview_expression(view, step_id, field_key, expression) do
    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{
      "type" => "preview_expression",
      "payload" => %{
        "step_id" => step_id,
        "field_key" => field_key,
        "expression" => expression
      }
    })

    key = preview_key(step_id, field_key)
    timer_ref = preview_timer_ref(view, key)

    send(view.pid, {:preview_expression, key, step_id, expression, timer_ref})
    render(view)
  end

  defp preview_key(step_id, field_key), do: "#{step_id}:#{field_key}"

  defp preview_timer_ref(view, key) do
    live_socket(view).assigns.preview_timers[key]
  end

  defp preview_value(view, key) do
    expression_previews(view)[key]
  end

  defp expression_previews(view) do
    live_socket(view).assigns.expression_previews
  end

  defp collaborator_presence(view, user_id) do
    live_socket(view).assigns.presences
    |> Enum.find(fn presence ->
      get_in(presence, [:user, :id]) == user_id
    end)
  end

  defp put_step_executions(view, step_executions) do
    :sys.replace_state(view.pid, fn state ->
      put_in(state.socket.assigns.step_executions, step_executions)
    end)
  end

  defp put_execution(view, execution) do
    :sys.replace_state(view.pid, fn state ->
      put_in(state.socket.assigns.execution, execution)
    end)
  end

  defp live_socket(view), do: :sys.get_state(view.pid).socket

  defp wait_for_run_status(scope, run_id, expected_status, attempts \\ 100)

  defp wait_for_run_status(scope, run_id, expected_status, attempts) when attempts > 0 do
    case Workflows.get_run(scope, run_id) do
      {:ok, %{status: ^expected_status} = run} ->
        {:ok, run}

      _ ->
        receive do
        after
          20 -> wait_for_run_status(scope, run_id, expected_status, attempts - 1)
        end
    end
  end

  defp wait_for_run_status(_scope, _run_id, _expected_status, 0) do
    flunk("run did not reach the expected status")
  end

  defp wait_for_worker_exit(run_id, attempts \\ 100)

  defp wait_for_worker_exit(run_id, attempts) when attempts > 0 do
    case Fizz.Workflows.Runner.Worker.lookup(run_id) do
      nil ->
        :ok

      _pid ->
        receive do
        after
          20 -> wait_for_worker_exit(run_id, attempts - 1)
        end
    end
  end

  defp wait_for_worker_exit(_run_id, 0) do
    flunk("worker did not exit")
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, attempts) when attempts > 0 do
    case fun.() do
      true ->
        :ok

      _other ->
        receive do
        after
          20 -> wait_until(fun, attempts - 1)
        end
    end
  end

  defp wait_until(_fun, 0) do
    flunk("condition was not met in time")
  end

  defp insert_api_credential!(user_id, organization_id, provider, provider_label) do
    unique = System.unique_integer([:positive])

    %ApiCredential{}
    |> ApiCredential.changeset(%{
      user_id: user_id,
      workos_organization_id: organization_id,
      provider: provider,
      provider_label: provider_label,
      vault_object_id: "vault_obj_#{unique}",
      vault_object_name: "vault_name_#{unique}"
    })
    |> Fizz.Repo.insert!()
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
