defmodule Fizz.WorkflowsTest do
  use Fizz.DataCase, async: false

  import Fizz.AccountsFixtures

  alias Fizz.Accounts.Scope
  alias Fizz.Repo
  alias Fizz.Workflows
  alias Fizz.Workflows.DurableTimer
  alias Fizz.Workflows.Runner.Worker
  alias Fizz.Workflows.Store.SqliteStore
  alias Fizz.Workflows.WorkflowRun
  alias Fizz.WorkflowsFixtures
  alias Runic.Workflow.{Fact, RunnableCompleted, RunnableDispatched, RunnableFailed}

  test "create definition with initial empty draft" do
    scope = project_scope_fixture()

    assert {:ok, %{definition: definition, draft: draft}} =
             Workflows.create_definition(scope, %{
               name: "Customer Intake",
               description: "Collect and route inbound requests"
             })

    assert definition.project_id == scope.project.id
    assert definition.workos_organization_id == scope.project.workos_organization_id
    assert definition.created_by_user_id == scope.user.id
    assert definition.archived_at == nil

    assert draft.workflow_definition_id == definition.id
    assert draft.version == 1
    assert draft.status == :draft
    assert draft.steps == []
    assert draft.connections == []
    assert draft.step_groups == []
    assert draft.viewport == %{"x" => 0, "y" => 0, "zoom" => 1.0}
    assert draft.settings == %{}
  end

  test "save draft with valid steps and connections" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    entry_step = step(%{type_id: "manual_input", name: "Entry"})
    debug_step = step(%{type_id: "debug", name: "Log"})

    attrs =
      snapshot_attrs(%{
        steps: [entry_step, debug_step],
        connections: [
          connection(%{
            source_step_id: entry_step.id,
            target_step_id: debug_step.id
          })
        ]
      })

    assert {:ok, saved_draft} = Workflows.save_draft(scope, draft, attrs)

    assert Enum.map(saved_draft.steps, & &1.id) == [entry_step.id, debug_step.id]
    assert Enum.map(saved_draft.connections, & &1.id) == [List.first(attrs.connections).id]
    assert saved_draft.step_groups == []
  end

  test "save draft rejects cyclic graphs" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    first_step = step(%{type_id: "debug", name: "First"})
    second_step = step(%{type_id: "debug", name: "Second"})

    attrs =
      snapshot_attrs(%{
        steps: [first_step, second_step],
        connections: [
          connection(%{source_step_id: first_step.id, target_step_id: second_step.id}),
          connection(%{source_step_id: second_step.id, target_step_id: first_step.id})
        ]
      })

    assert {:error, changeset} = Workflows.save_draft(scope, draft, attrs)
    assert_message!(errors_on(changeset).connections, "creates a cycle")
  end

  test "save draft rejects unknown type ids" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    attrs =
      snapshot_attrs(%{
        steps: [step(%{type_id: "missing_step_type", name: "Missing"})]
      })

    assert {:error, changeset} = Workflows.save_draft(scope, draft, attrs)
    assert_message!(errors_on(changeset).steps, "unknown step types")
  end

  test "save draft rejects duplicate step ids" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    duplicate_id = Ecto.UUID.generate()

    attrs =
      snapshot_attrs(%{
        steps: [
          step(%{id: duplicate_id, name: "First"}),
          step(%{id: duplicate_id, name: "Second"})
        ]
      })

    assert {:error, changeset} = Workflows.save_draft(scope, draft, attrs)
    assert_message!(errors_on(changeset).steps, "duplicate step ids")
  end

  test "publish draft stamps published_at and compiled_hash" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    assert {:ok, saved_draft} =
             Workflows.save_draft(scope, draft, valid_snapshot_attrs())

    assert {:ok, published_version} = Workflows.publish_draft(scope, saved_draft)

    assert published_version.status == :published
    assert %DateTime{} = published_version.published_at
    assert published_version.published_by_user_id == scope.user.id
    assert is_binary(published_version.compiled_hash)
    assert byte_size(published_version.compiled_hash) == 64
  end

  test "publish draft rejects when no entry step exists" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    assert {:error, changeset} = Workflows.publish_draft(scope, draft)
    assert_message!(errors_on(changeset).steps, "at least one entry step")
  end

  test "publish draft rejects invalid step config" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    invalid_http_step =
      step(%{
        type_id: "http_request",
        name: "HTTP Request",
        config: %{}
      })

    assert {:ok, saved_draft} =
             Workflows.save_draft(scope, draft, snapshot_attrs(%{steps: [invalid_http_step]}))

    assert {:error, changeset} = Workflows.publish_draft(scope, saved_draft)
    assert_message!(errors_on(changeset).steps, "invalid config")
  end

  test "publish draft rejects unsupported expression filters" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    debug_step =
      step(%{
        type_id: "debug",
        name: "Debug",
        config: %{"label" => "{{ input.name | concat: \"!\" }}"}
      })

    assert {:ok, saved_draft} =
             Workflows.save_draft(scope, draft, snapshot_attrs(%{steps: [debug_step]}))

    assert {:error, changeset} = Workflows.publish_draft(scope, saved_draft)
    assert_message!(errors_on(changeset).steps, "unsupported filter `concat`")
  end

  test "publish draft rejects invalid step expression references" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    debug_step =
      step(%{
        type_id: "debug",
        name: "Debug",
        config: %{"label" => "{{ steps.#{Ecto.UUID.generate()}.body }}"}
      })

    assert {:ok, saved_draft} =
             Workflows.save_draft(scope, draft, snapshot_attrs(%{steps: [debug_step]}))

    assert {:error, changeset} = Workflows.publish_draft(scope, saved_draft)
    assert_message!(errors_on(changeset).steps, "unknown step reference")
  end

  test "published version is immutable" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    assert {:ok, saved_draft} =
             Workflows.save_draft(scope, draft, valid_snapshot_attrs())

    assert {:ok, published_version} = Workflows.publish_draft(scope, saved_draft)

    assert {:error, :not_a_draft} =
             Workflows.save_draft(scope, published_version, valid_snapshot_attrs())
  end

  test "edit after publish clones to new draft" do
    scope = project_scope_fixture()
    %{definition: definition, draft: draft} = definition_fixture(scope)

    assert {:ok, saved_draft} =
             Workflows.save_draft(scope, draft, valid_snapshot_attrs())

    assert {:ok, published_version} = Workflows.publish_draft(scope, saved_draft)
    assert {:ok, cloned_draft} = Workflows.edit_definition(scope, definition)

    assert cloned_draft.id != published_version.id
    assert cloned_draft.version == 2
    assert cloned_draft.status == :draft
    assert Enum.map(cloned_draft.steps, & &1.id) == Enum.map(published_version.steps, & &1.id)

    assert Enum.map(cloned_draft.connections, & &1.id) ==
             Enum.map(published_version.connections, & &1.id)

    assert cloned_draft.compiled_hash == nil
    assert cloned_draft.published_at == nil
    assert cloned_draft.published_by_user_id == nil
  end

  test "archive hides from list queries" do
    scope = project_scope_fixture()
    %{definition: definition} = definition_fixture(scope)

    assert {:ok, [listed_definition]} = Workflows.list_definitions(scope)
    assert listed_definition.id == definition.id

    assert {:ok, archived_definition} = Workflows.archive_definition(scope, definition)
    assert %DateTime{} = archived_definition.archived_at
    assert {:ok, []} = Workflows.list_definitions(scope)
  end

  test "start_run executes steps and transitions to completed" do
    scope = WorkflowsFixtures.project_scope_fixture()
    %{version: version} = WorkflowsFixtures.published_version_fixture(scope)

    assert {:ok, run} = Workflows.start_run(scope, version, %{"name" => "Ada"})

    completed_run =
      eventually(fn ->
        with {:ok, workflow_run} <- Workflows.get_run(scope, run.id),
             true <- workflow_run.status == :completed do
          {:ok, workflow_run}
        else
          _ -> :retry
        end
      end)

    assert completed_run.status == :completed
    assert completed_run.output != nil
    assert_worker_shutdown(run.id)
  end

  test "complete_run normalizes structs in output payloads" do
    scope = WorkflowsFixtures.project_scope_fixture()
    %{version: version} = WorkflowsFixtures.published_version_fixture(scope)
    run = insert_running_run(scope, version)

    response = %ReqLLM.Response{
      id: "resp_test",
      model: "test-model",
      context: nil,
      message: %ReqLLM.Message{
        role: :assistant,
        content: [ReqLLM.Message.ContentPart.text("done")]
      },
      usage: %{input_tokens: 7, output_tokens: 3, total_tokens: 10},
      finish_reason: :stop
    }

    assert {:ok, completed_run} =
             Workflows.complete_run(run.id, %{
               "response" => response,
               "finished_at" => run.started_at
             })

    assert completed_run.status == :completed
    assert completed_run.output["response"]["id"] == "resp_test"

    assert completed_run.output["response"]["message"]["content"] == [
             %{
               "data" => nil,
               "file_id" => nil,
               "filename" => nil,
               "media_type" => nil,
               "metadata" => %{},
               "text" => "done",
               "type" => ":text",
               "url" => nil
             }
           ]

    assert completed_run.output["finished_at"] == DateTime.to_iso8601(run.started_at)
  end

  describe "terminal finalization" do
    test "complete_run cancels pending timers and releases the lease" do
      scope = WorkflowsFixtures.project_scope_fixture()
      %{version: version} = WorkflowsFixtures.published_version_fixture(scope)
      run = insert_running_run(scope, version)
      timer = insert_terminal_cleanup_timer(run)
      insert_owned_lease(run.id, 1)

      assert {:ok, %{status: :completed}} = Workflows.complete_run(run.id, %{"ok" => true})

      assert %{status: :cancelled} = Repo.get!(DurableTimer, timer.id)
      assert lease_released?(run.id)
    end

    test "fail_run cancels pending timers and releases the lease" do
      scope = WorkflowsFixtures.project_scope_fixture()
      %{version: version} = WorkflowsFixtures.published_version_fixture(scope)
      run = insert_running_run(scope, version)
      timer = insert_terminal_cleanup_timer(run)
      insert_owned_lease(run.id, 1)

      assert {:ok, %{status: :failed}} = Workflows.fail_run(run.id, %{reason: "boom"})

      assert %{status: :cancelled} = Repo.get!(DurableTimer, timer.id)
      assert lease_released?(run.id)
    end

    test "cancel_run cancels pending timers and releases the lease" do
      scope = WorkflowsFixtures.project_scope_fixture()
      %{version: version} = WorkflowsFixtures.published_version_fixture(scope)
      run = insert_running_run(scope, version)
      timer = insert_terminal_cleanup_timer(run)
      insert_owned_lease(run.id, 1)

      assert {:ok, %{status: :cancelled}} = Workflows.cancel_run(scope, run.id)

      assert %{status: :cancelled} = Repo.get!(DurableTimer, timer.id)
      assert lease_released?(run.id)
    end
  end

  test "start_run requires bindings for declared credentials" do
    scope = WorkflowsFixtures.project_scope_fixture()

    entry_step = WorkflowsFixtures.step(%{type_id: "debug", name: "Entry"})

    image_step =
      WorkflowsFixtures.step(%{
        type_id: "openai_image_generation",
        name: "Image",
        config:
          "openai_image_generation"
          |> Fizz.Integrations.Steps.Registry.get_default_config()
          |> Map.put("prompt", "a generated product mockup")
      })

    snapshot_attrs =
      WorkflowsFixtures.snapshot_attrs(%{
        steps: [entry_step, image_step],
        connections: [
          WorkflowsFixtures.connection(%{
            source_step_id: entry_step.id,
            target_step_id: image_step.id
          })
        ]
      })

    %{version: version} = WorkflowsFixtures.published_version_fixture(scope, snapshot_attrs)

    assert {:error, {:credential_bindings_required, [descriptor]}} =
             Workflows.start_run(scope, version, %{})

    assert descriptor.step_id == image_step.id
    assert descriptor.requirement_key == "auth"
    assert descriptor.provider == "openai_api_key"
    assert descriptor.auth_type == "api_key"
  end

  test "list_run_step_executions exposes split iterations without compiler internals" do
    scope = WorkflowsFixtures.project_scope_fixture()

    trigger = WorkflowsFixtures.step(%{type_id: "manual_input", name: "Manual"})

    splitter =
      WorkflowsFixtures.step(%{
        type_id: "splitter",
        name: "Split",
        config: %{"field" => "{{ json.items }}"}
      })

    debug = WorkflowsFixtures.step(%{type_id: "debug", name: "Debug"})

    snapshot_attrs =
      WorkflowsFixtures.snapshot_attrs(%{
        steps: [trigger, splitter, debug],
        connections: [
          WorkflowsFixtures.connection(%{
            source_step_id: trigger.id,
            target_step_id: splitter.id
          }),
          WorkflowsFixtures.connection(%{
            source_step_id: splitter.id,
            target_step_id: debug.id
          })
        ]
      })

    %{version: version} = WorkflowsFixtures.published_version_fixture(scope, snapshot_attrs)

    assert {:ok, run} = Workflows.start_run(scope, version, %{"items" => [1, 2, 3]})

    _completed_run =
      eventually(fn ->
        with {:ok, workflow_run} <- Workflows.get_run(scope, run.id),
             true <- workflow_run.status == :completed do
          {:ok, workflow_run}
        else
          _ -> :retry
        end
      end)

    assert {:ok, step_executions} = Workflows.list_run_step_executions(scope, run.id)

    step_ids =
      step_executions
      |> Enum.map(& &1.step_id)
      |> Enum.uniq()
      |> Enum.sort()

    assert step_ids == Enum.sort([trigger.id, splitter.id, debug.id])
    refute Enum.any?(step_executions, &String.contains?(&1.step_id, "__"))

    splitter_executions =
      step_executions
      |> Enum.filter(&(&1.step_id == splitter.id))
      |> Enum.sort_by(& &1.item_index)

    assert Enum.map(splitter_executions, & &1.item_index) == [0, 1, 2]
    assert Enum.map(splitter_executions, & &1.items_total) == [3, 3, 3]
    assert Enum.map(splitter_executions, & &1.input_data) == [[1, 2, 3], [1, 2, 3], [1, 2, 3]]
    assert Enum.map(splitter_executions, & &1.output_data) == [1, 2, 3]

    debug_executions =
      step_executions
      |> Enum.filter(&(&1.step_id == debug.id))
      |> Enum.sort_by(& &1.item_index)

    assert Enum.map(debug_executions, & &1.item_index) == [0, 1, 2]
    assert Enum.map(debug_executions, & &1.items_total) == [3, 3, 3]
    assert Enum.map(debug_executions, & &1.input_data) == [1, 2, 3]

    assert_worker_shutdown(run.id)
  end

  test "completed run output excludes internal splitter artifacts and preserves iteration metadata downstream" do
    scope = WorkflowsFixtures.project_scope_fixture()

    trigger = WorkflowsFixtures.step(%{type_id: "manual_input", name: "Manual Trigger"})

    debug =
      WorkflowsFixtures.step(%{
        type_id: "debug",
        name: "Inspect Request",
        config: %{"label" => "Incoming request", "level" => "info"}
      })

    output = WorkflowsFixtures.step(%{type_id: "data_output", name: "Output"})

    splitter =
      WorkflowsFixtures.step(%{
        type_id: "splitter",
        name: "Split Items",
        config: %{"field" => "{{ json.email }}"}
      })

    math =
      WorkflowsFixtures.step(%{
        type_id: "math",
        name: "Math",
        config: %{"operation" => "add", "value" => "{{ input }}", "operand" => 10}
      })

    snapshot_attrs =
      WorkflowsFixtures.snapshot_attrs(%{
        steps: [trigger, debug, output, splitter, math],
        connections: [
          WorkflowsFixtures.connection(%{
            source_step_id: trigger.id,
            target_step_id: debug.id
          }),
          WorkflowsFixtures.connection(%{
            source_step_id: debug.id,
            target_step_id: output.id
          }),
          WorkflowsFixtures.connection(%{
            source_step_id: trigger.id,
            target_step_id: splitter.id
          }),
          WorkflowsFixtures.connection(%{
            source_step_id: splitter.id,
            target_step_id: math.id
          })
        ]
      })

    %{version: version} = WorkflowsFixtures.published_version_fixture(scope, snapshot_attrs)

    assert {:ok, run} = Workflows.start_run(scope, version, %{"email" => [1, 2, 3]})

    completed_run =
      eventually(fn ->
        with {:ok, workflow_run} <- Workflows.get_run(scope, run.id),
             true <- workflow_run.status == :completed do
          {:ok, workflow_run}
        else
          _ -> :retry
        end
      end)

    assert completed_run.output == %{"value" => [%{"email" => [1, 2, 3]}]}

    assert {:ok, step_executions} = Workflows.list_run_step_executions(scope, run.id)

    step_ids =
      step_executions
      |> Enum.map(& &1.step_id)
      |> Enum.uniq()
      |> Enum.sort()

    assert step_ids == Enum.sort([trigger.id, debug.id, output.id, splitter.id, math.id])

    splitter_executions =
      step_executions
      |> Enum.filter(&(&1.step_id == splitter.id))
      |> Enum.sort_by(& &1.item_index)

    assert Enum.map(splitter_executions, & &1.item_index) == [0, 1, 2]
    assert Enum.map(splitter_executions, & &1.items_total) == [3, 3, 3]
    assert Enum.map(splitter_executions, & &1.input_data) == [[1, 2, 3], [1, 2, 3], [1, 2, 3]]
    assert Enum.map(splitter_executions, & &1.output_data) == [1, 2, 3]

    math_executions =
      step_executions
      |> Enum.filter(&(&1.step_id == math.id))
      |> Enum.sort_by(& &1.item_index)

    assert Enum.map(math_executions, & &1.item_index) == [0, 1, 2]
    assert Enum.map(math_executions, & &1.items_total) == [3, 3, 3]
    assert Enum.map(math_executions, & &1.input_data) == [1, 2, 3]
    assert Enum.map(math_executions, & &1.output_data) == [11.0, 12.0, 13.0]

    assert_worker_shutdown(run.id)
  end

  test "cancel_run transitions the run to cancelled and stops the worker" do
    scope = WorkflowsFixtures.project_scope_fixture()

    %{version: version} =
      WorkflowsFixtures.published_version_fixture(
        scope,
        WorkflowsFixtures.long_running_snapshot_attrs(1_000)
      )

    assert {:ok, run} = Workflows.start_run(scope, version, %{"name" => "Ada"})

    pid =
      eventually(fn ->
        case {Worker.lookup(run.id), Workflows.get_run(scope, run.id)} do
          {worker_pid, {:ok, %{status: :sleeping}}} when is_pid(worker_pid) ->
            {:ok, worker_pid}

          _ ->
            :retry
        end
      end)

    ref = Process.monitor(pid)

    assert {:ok, cancelled_run} = Workflows.cancel_run(scope, run.id)
    assert cancelled_run.status == :cancelled
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    assert {:ok, %{status: :cancelled}} = Workflows.get_run(scope, run.id)
  end

  test "list_run_step_executions preserves microsecond durations from persisted completed events" do
    scope = WorkflowsFixtures.project_scope_fixture()
    step = WorkflowsFixtures.step(%{type_id: "debug", name: "Fast Step"})

    %{version: version} =
      WorkflowsFixtures.published_version_fixture(
        scope,
        WorkflowsFixtures.snapshot_attrs(%{steps: [step]})
      )

    run = insert_completed_run(scope, version)
    tmp_dir = unique_tmp_dir("step-execution-duration")
    configure_workflow_data_dir(tmp_dir)
    insert_lease(run.id, 1)

    {:ok, store_state} =
      SqliteStore.init(run.id,
        data_dir: tmp_dir,
        org_id: scope.project.workos_organization_id,
        project_id: scope.project.id,
        fence_token: 1,
        repo: Repo
      )

    input_fact = %Fact{hash: 101, value: %{"email" => "test"}}

    output_fact = %Fact{
      hash: 202,
      value: %{"email" => "test"},
      ancestry: {303, input_fact.hash}
    }

    event_log = [
      %RunnableDispatched{
        runnable_id: 123,
        node_name: step.id,
        node_hash: 303,
        input_fact: input_fact,
        dispatched_at: 0,
        policy: nil,
        attempt: 0
      },
      %RunnableCompleted{
        runnable_id: 123,
        node_hash: 303,
        result_fact: output_fact,
        completed_at: 0,
        attempt: 0,
        duration_ms: 0,
        duration_us: 713
      }
    ]

    assert :ok = SqliteStore.save(run.id, event_log, store_state)

    assert {:ok,
            [%{duration_us: 713, output_item_count: 1, status: "completed", step_id: step_id}]} =
             Workflows.list_run_step_executions(scope, run.id)

    assert step_id == step.id
  end

  test "list_run_step_executions preserves microsecond durations from persisted failed events" do
    scope = WorkflowsFixtures.project_scope_fixture()
    step = WorkflowsFixtures.step(%{type_id: "debug", name: "Fast Failure"})

    %{version: version} =
      WorkflowsFixtures.published_version_fixture(
        scope,
        WorkflowsFixtures.snapshot_attrs(%{steps: [step]})
      )

    run = insert_failed_run(scope, version)
    tmp_dir = unique_tmp_dir("step-execution-failure-duration")
    configure_workflow_data_dir(tmp_dir)
    insert_lease(run.id, 1)

    {:ok, store_state} =
      SqliteStore.init(run.id,
        data_dir: tmp_dir,
        org_id: scope.project.workos_organization_id,
        project_id: scope.project.id,
        fence_token: 1,
        repo: Repo
      )

    input_fact = %Fact{hash: 404, value: %{"email" => "test"}}

    event_log = [
      %RunnableDispatched{
        runnable_id: 456,
        node_name: step.id,
        node_hash: 505,
        input_fact: input_fact,
        dispatched_at: 0,
        policy: nil,
        attempt: 0
      },
      %RunnableFailed{
        runnable_id: 456,
        node_hash: 505,
        error: :boom,
        failed_at: 0,
        duration_us: 811,
        attempts: 1,
        failure_action: :halt
      }
    ]

    assert :ok = SqliteStore.save(run.id, event_log, store_state)

    assert {:ok, [%{duration_us: 811, status: "failed", step_id: step_id}]} =
             Workflows.list_run_step_executions(scope, run.id)

    assert step_id == step.id
  end

  defp definition_fixture(scope) do
    {:ok, %{definition: definition, draft: draft}} =
      Workflows.create_definition(scope, %{
        name: "Workflow #{System.unique_integer([:positive])}",
        description: "Draft definition"
      })

    %{definition: definition, draft: draft}
  end

  defp project_scope_fixture do
    user = user_fixture()
    organization_scope = organization_scope_fixture(user: user)

    project =
      project_fixture(organization_scope, %{name: "Project #{System.unique_integer([:positive])}"})

    organization_scope
    |> Scope.with_project(project)
    |> Scope.with_project_role(:admin)
  end

  defp valid_snapshot_attrs do
    entry_step = step(%{type_id: "manual_input", name: "Entry"})
    debug_step = step(%{type_id: "debug", name: "Debug"})

    snapshot_attrs(%{
      steps: [entry_step, debug_step],
      connections: [
        connection(%{source_step_id: entry_step.id, target_step_id: debug_step.id})
      ]
    })
  end

  defp snapshot_attrs(overrides) do
    Map.merge(
      %{
        steps: [],
        connections: [],
        step_groups: [],
        viewport: %{"x" => 0, "y" => 0, "zoom" => 1.0},
        settings: %{}
      },
      overrides
    )
  end

  defp step(attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        type_id: "debug",
        name: "Step #{System.unique_integer([:positive])}",
        config: %{},
        position: %{"x" => 100, "y" => 100},
        notes: nil
      },
      attrs
    )
  end

  defp connection(attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        source_step_id: Ecto.UUID.generate(),
        source_output: "main",
        target_step_id: Ecto.UUID.generate(),
        target_input: "main"
      },
      attrs
    )
  end

  defp assert_message!(messages, expected_substring) do
    assert Enum.any?(messages, &String.contains?(&1, expected_substring))
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        receive do
        after
          20 -> eventually(fun, attempts - 1)
        end
    end
  end

  defp eventually(_fun, 0), do: flunk("condition was not met in time")

  defp assert_worker_shutdown(run_id) do
    case Worker.lookup(run_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end
  end

  defp insert_running_run(scope, version) do
    now = DateTime.utc_now()

    %WorkflowRun{}
    |> WorkflowRun.changeset(%{
      user_id: scope.user.id,
      workflow_definition_id: version.workflow_definition_id,
      workflow_definition_version_id: version.id,
      project_id: scope.project.id,
      workos_organization_id: scope.project.workos_organization_id,
      status: :running,
      input: %{},
      last_active_at: now,
      started_at: now
    })
    |> Repo.insert!()
  end

  defp insert_completed_run(scope, version) do
    now = DateTime.utc_now()

    %WorkflowRun{}
    |> WorkflowRun.changeset(%{
      user_id: scope.user.id,
      workflow_definition_id: version.workflow_definition_id,
      workflow_definition_version_id: version.id,
      project_id: scope.project.id,
      workos_organization_id: scope.project.workos_organization_id,
      status: :completed,
      input: %{},
      output: %{},
      last_active_at: now,
      started_at: now,
      completed_at: now
    })
    |> Repo.insert!()
  end

  defp insert_failed_run(scope, version) do
    now = DateTime.utc_now()

    %WorkflowRun{}
    |> WorkflowRun.changeset(%{
      user_id: scope.user.id,
      workflow_definition_id: version.workflow_definition_id,
      workflow_definition_version_id: version.id,
      project_id: scope.project.id,
      workos_organization_id: scope.project.workos_organization_id,
      status: :failed,
      input: %{},
      error: %{"message" => "boom"},
      last_active_at: now,
      started_at: now,
      completed_at: now
    })
    |> Repo.insert!()
  end

  defp insert_lease(run_id, fence_token) do
    assert {:ok, _result} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               INSERT INTO workflow_run_leases (run_id, owner_node, fence_token, checkpoint_seq, lease_expiry)
               VALUES ($1, NULL, $2, 0, NOW() + interval '30 seconds')
               """,
               [dump_uuid(run_id), fence_token]
             )
  end

  defp insert_owned_lease(run_id, fence_token) do
    assert {:ok, _result} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               INSERT INTO workflow_run_leases (run_id, owner_node, fence_token, checkpoint_seq, lease_expiry)
               VALUES ($1, $2, $3, 0, NOW() + interval '30 seconds')
               """,
               [dump_uuid(run_id), Atom.to_string(node()), fence_token]
             )
  end

  defp insert_terminal_cleanup_timer(run) do
    %DurableTimer{}
    |> DurableTimer.changeset(%{
      run_id: run.id,
      step_id: "terminal-cleanup",
      timer_name: "terminal-cleanup",
      project_id: run.project_id,
      workos_organization_id: run.workos_organization_id,
      fire_at: DateTime.add(DateTime.utc_now(), 1, :hour),
      status: :pending,
      payload: %{}
    })
    |> Repo.insert!()
  end

  defp lease_released?(run_id) do
    assert {:ok, %{rows: [[lease_expiry]]}} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               SELECT lease_expiry
               FROM workflow_run_leases
               WHERE run_id = $1
               """,
               [dump_uuid(run_id)]
             )

    NaiveDateTime.compare(lease_expiry, NaiveDateTime.utc_now()) == :lt
  end

  defp dump_uuid(run_id), do: Ecto.UUID.dump!(run_id)

  defp unique_tmp_dir(prefix) do
    tmp_dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    tmp_dir
  end

  defp configure_workflow_data_dir(tmp_dir) do
    previous = Application.get_env(:fizz, :workflow_data_dir)
    Application.put_env(:fizz, :workflow_data_dir, tmp_dir)

    on_exit(fn ->
      Application.put_env(:fizz, :workflow_data_dir, previous)
    end)
  end
end
