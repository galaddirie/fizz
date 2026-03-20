defmodule FizzWeb.WorkflowEditorLiveTest do
  use FizzWeb.ConnCase, async: false

  import LiveVue.Test
  import Phoenix.LiveViewTest

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
    assert vue.props["workflow"]["project_id"] == definition.project_id
    assert vue.props["workflow"]["name"] == definition.name
    assert vue.props["workflow"]["created_by_user_id"] == definition.created_by_user_id
    assert vue.props["workflow"]["draft"]["id"] == draft.id
    assert vue.props["workflow"]["draft"]["workflow_definition_id"] == definition.id
    assert vue.props["workflow"]["draft"]["version"] == draft.version
    assert vue.props["workflow"]["draft"]["status"] == "draft"
    assert vue.props["workflow"]["draft"]["step_groups"] == []
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

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

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

  test "run_test persists the current draft before compiling", %{conn: conn} do
    %{conn: conn, definition: definition, project_scope: project_scope} = editor_fixture(conn)

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

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

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
  end

  test "publish_workflow persists before validation and blocks on validation errors", %{
    conn: conn
  } do
    %{conn: conn, definition: definition, project_scope: project_scope} = editor_fixture(conn)

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

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

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

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

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

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

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

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

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

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

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

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

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

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

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

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
               duration_us: 12_000
             }
           ] =
             live_socket(view).assigns.step_executions
  end

  test "terminal status unsubscribes from the run topic", %{conn: conn} do
    snapshot_attrs = WorkflowsFixtures.long_running_snapshot_attrs(5_000)

    %{conn: conn, definition: definition, project_scope: project_scope} =
      editor_fixture(conn, snapshot_attrs)

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

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

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

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

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

    view
    |> element("#workflow-editor")
    |> render_hook("editor_command", %{"type" => "run_test", "payload" => %{}})

    assert_push_event(view, "compilation_errors", %{errors: [%{message: message} | _rest]})
    assert message =~ "trigger steps must be graph roots with no incoming connections"
    assert live_socket(view).assigns.execution == nil
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

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{definition.project_id}/workflows/#{definition.id}/edit")

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

  defp view_version_id(view) do
    vue = get_vue(view, id: "workflow-editor")
    vue.props["workflow"]["draft"]["id"]
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
