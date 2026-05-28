defmodule Fizz.Workflows.Runner.WorkerFailureTest do
  use Fizz.DataCase, async: false

  import Fizz.WorkflowsFixtures

  alias Fizz.Workflows
  alias Fizz.Workflows.Compiler
  alias Fizz.Workflows.DurableTimer
  alias Fizz.Workflows.RetryPolicy
  alias Fizz.Workflows.StepError
  alias Fizz.Workflows.Runner.RunnableConsumerSupervisor
  alias Fizz.Workflows.Runner.RunnableDispatcher
  alias Fizz.Workflows.Runner.Worker
  alias Fizz.Workflows.Runtime.ContextBuilder
  alias Fizz.Workflows.StepExecutionError
  alias Fizz.Workflows.Store.SqliteStore
  alias Fizz.Workflows.WorkflowRun

  require Runic

  setup do
    scope = project_scope_fixture()
    registry = unique_name(:registry)
    task_supervisor = unique_name(:task_supervisor)
    runnable_dispatcher = unique_name(:runnable_dispatcher)
    runnable_consumer_supervisor = unique_name(:runnable_consumer_supervisor)

    tmp_dir =
      Path.join(System.tmp_dir!(), "fizz-worker-failure-#{System.unique_integer([:positive])}")

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Task.Supervisor, name: task_supervisor})
    start_supervised!({RunnableDispatcher, name: runnable_dispatcher})

    start_supervised!(
      {RunnableConsumerSupervisor,
       name: runnable_consumer_supervisor,
       dispatcher: runnable_dispatcher,
       task_supervisor: task_supervisor,
       max_concurrency: 4}
    )

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    %{
      scope: scope,
      registry: registry,
      task_supervisor: task_supervisor,
      runnable_dispatcher: runnable_dispatcher,
      tmp_dir: tmp_dir
    }
  end

  describe "task crash (:DOWN)" do
    test "task crash -> step :failed, run :failed",
         %{
           scope: scope,
           registry: registry,
           task_supervisor: task_supervisor,
           runnable_dispatcher: runnable_dispatcher,
           tmp_dir: tmp_dir
         } do
      test_pid = self()

      workflow =
        Runic.Workflow.new()
        |> Runic.Workflow.add(
          Runic.step(
            fn input ->
              send(test_pid, {:task_running, self()})

              receive do
                :release -> input
              end
            end,
            name: :blocking_step
          )
        )

      %{version: version} = published_version_fixture(scope)
      run = insert_running_run(scope, version, %{compiled_hash: nil})

      Phoenix.PubSub.subscribe(Fizz.PubSub, "workflow_run:#{run.id}")

      pid =
        start_worker!(workflow, run, scope,
          registry: registry,
          task_supervisor: task_supervisor,
          runnable_dispatcher: runnable_dispatcher,
          tmp_dir: tmp_dir
        )

      Worker.run(pid, %{})

      # Wait for the task to be running
      assert_receive {:task_running, task_pid}, 2_000

      # Kill the task process to trigger the :DOWN handler
      Process.exit(task_pid, :kill)

      assert_receive {:step_failed, %{run_id: run_id}}, 5_000
      assert run_id == run.id

      assert_receive {:run_status_changed, %{run_id: ^run_id, status: :failed}}, 5_000

      assert {:ok, %{status: :failed}} = Workflows.get_run(scope, run.id)
    end

    test "large errors are summarized in step failure broadcasts",
         %{
           scope: scope,
           registry: registry,
           task_supervisor: task_supervisor,
           runnable_dispatcher: runnable_dispatcher,
           tmp_dir: tmp_dir
         } do
      workflow =
        Runic.Workflow.new()
        |> Runic.Workflow.add(
          Runic.step(
            fn _input ->
              raise RuntimeError, message: String.duplicate("x", 5_000)
            end,
            name: :large_failure
          )
        )

      %{version: version} = published_version_fixture(scope)
      run = insert_running_run(scope, version, %{compiled_hash: nil})
      run_id = run.id

      Phoenix.PubSub.subscribe(Fizz.PubSub, "workflow_run:#{run_id}")

      pid =
        start_worker!(workflow, run, scope,
          registry: registry,
          task_supervisor: task_supervisor,
          runnable_dispatcher: runnable_dispatcher,
          tmp_dir: tmp_dir
        )

      Worker.run(pid, %{"large" => String.duplicate("y", 5_000)})

      assert_receive {:step_failed,
                      %{
                        run_id: ^run_id,
                        input_summary: input_summary,
                        error: %{message: message, details: %{inspect: inspect_summary}}
                      } = payload},
                     5_000

      assert byte_size(input_summary) <= 1_027
      assert byte_size(message) <= 1_027
      assert byte_size(inspect_summary) <= 1_027
      refute Map.has_key?(payload, :input)

      assert_receive {:run_status_changed, %{run_id: ^run_id, status: :failed}}, 5_000
      assert {:ok, %{status: :failed}} = Workflows.get_run(scope, run.id)
    end
  end

  describe "step retries" do
    test "retryable step errors sleep the run and resume the runnable",
         %{
           scope: scope,
           registry: registry,
           task_supervisor: task_supervisor,
           runnable_dispatcher: runnable_dispatcher,
           tmp_dir: tmp_dir
         } do
      attempts = start_supervised!({Agent, fn -> 0 end})

      workflow =
        Runic.Workflow.new()
        |> Runic.Workflow.add(
          Runic.step(
            fn input ->
              attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})

              case attempt do
                0 ->
                  raise StepExecutionError.exception(
                          reason:
                            StepError.new(
                              code: :network_error,
                              category: :network,
                              message: "Network request failed",
                              source: :google_sheets,
                              retry_after_ms: 0,
                              retryable?: true,
                              details: %{
                                reason: :timeout
                              }
                            ),
                          step_id: "retry_step",
                          step_type_id: "google_sheets_append_row",
                          retry: %RetryPolicy{max_attempts: 3}
                        )

                _ ->
                  Map.put(input, "attempt", attempt)
              end
            end,
            name: :retry_step
          )
        )

      %{version: version} = published_version_fixture(scope)
      run = insert_running_run(scope, version, %{compiled_hash: nil})
      run_id = run.id

      Phoenix.PubSub.subscribe(Fizz.PubSub, "workflow_run:#{run_id}")

      pid =
        start_worker!(workflow, run, scope,
          registry: registry,
          task_supervisor: task_supervisor,
          runnable_dispatcher: runnable_dispatcher,
          tmp_dir: tmp_dir,
          idle_timeout_ms: 0
        )

      Worker.run(pid, %{"value" => "ok"})

      assert_receive {:step_started, %{run_id: ^run_id, step_id: "retry_step", attempt: 0}},
                     2_000

      assert_receive {:step_failed,
                      %{
                        run_id: ^run_id,
                        step_id: "retry_step",
                        attempt: 0,
                        error: %{type: "step_execution_error"}
                      }},
                     2_000

      assert_receive {:run_status_changed, %{run_id: ^run_id, status: :sleeping}}, 2_000

      assert {:ok,
              %{
                status: :sleeping,
                error: %{
                  "type" => "step_retry",
                  "step_type_id" => "google_sheets_append_row",
                  "failed_attempt" => 1,
                  "next_attempt" => 1
                }
              }} = Workflows.get_run(scope, run_id)

      assert {:ok, [timer]} =
               Workflows.claim_due_timers(now: DateTime.utc_now(), claimed_by: "retry-test")

      assert timer.run_id == run_id
      assert :ok = Workflows.deliver_run_event(run_id, {:timer_fired, timer}, registry: registry)

      assert_receive {:run_status_changed, %{run_id: ^run_id, status: :running}}, 2_000

      assert_receive {:step_started, %{run_id: ^run_id, step_id: "retry_step", attempt: 1}},
                     2_000

      assert_receive {:step_completed, %{run_id: ^run_id, step_id: "retry_step", attempt: 1}},
                     2_000

      assert_receive {:run_status_changed, %{run_id: ^run_id, status: :completed}}, 2_000

      assert {:ok,
              %{
                status: :completed,
                error: nil,
                output: %{"value" => [%{"attempt" => 1, "value" => "ok"}]}
              }} =
               Workflows.get_run(scope, run_id)

      refute_receive {:run_status_changed, %{run_id: ^run_id, status: :failed}}, 100
    end
  end

  describe "fail_and_stop/2 broadcasts :step_cancelled for active siblings" do
    test "step fails with concurrent siblings -> causal step :failed, siblings :cancelled, run :failed",
         %{
           scope: scope,
           registry: registry,
           task_supervisor: task_supervisor,
           runnable_dispatcher: runnable_dispatcher,
           tmp_dir: tmp_dir
         } do
      test_pid = self()

      # Build a workflow where :entry fans out to :sibling_a and :sibling_b
      # Both siblings block, allowing us to kill one and observe the other getting cancelled
      workflow =
        Runic.Workflow.new()
        |> Runic.Workflow.add(Runic.step(fn input -> input end, name: :entry))
        |> Runic.Workflow.add(
          Runic.step(
            fn input ->
              send(test_pid, {:sibling_a_running, self()})
              receive do: (:release -> input)
            end,
            name: :sibling_a
          ),
          to: :entry
        )
        |> Runic.Workflow.add(
          Runic.step(
            fn input ->
              send(test_pid, {:sibling_b_running, self()})
              receive do: (:release -> input)
            end,
            name: :sibling_b
          ),
          to: :entry
        )

      %{version: version} = published_version_fixture(scope)
      run = insert_running_run(scope, version, %{compiled_hash: nil})

      Phoenix.PubSub.subscribe(Fizz.PubSub, "workflow_run:#{run.id}")

      pid =
        start_worker!(workflow, run, scope,
          registry: registry,
          task_supervisor: task_supervisor,
          runnable_dispatcher: runnable_dispatcher,
          tmp_dir: tmp_dir,
          max_concurrency: 4
        )

      Worker.run(pid, %{})

      # Wait for both siblings to be running
      assert_receive {:sibling_a_running, sibling_a_pid}, 2_000
      assert_receive {:sibling_b_running, _sibling_b_pid}, 2_000

      # Flush any prior broadcast messages (entry step events)
      flush_mailbox()

      # Kill sibling_a to trigger fail_and_stop
      Process.exit(sibling_a_pid, :kill)

      # The causal step should get :step_failed
      assert_receive {:step_failed, %{run_id: run_id}}, 5_000
      assert run_id == run.id

      # The sibling should get :step_cancelled
      assert_receive {:step_cancelled, %{run_id: ^run_id, cancelled_at: %DateTime{}}}, 5_000

      # Run should be failed
      assert_receive {:run_status_changed, %{run_id: ^run_id, status: :failed}}, 5_000

      assert {:ok, %{status: :failed}} = Workflows.get_run(scope, run.id)
    end
  end

  describe "checkpoint failure resilience" do
    test "checkpoint failure during fail_and_stop -> run still :failed in DB",
         %{
           scope: scope,
           registry: registry,
           task_supervisor: task_supervisor,
           runnable_dispatcher: runnable_dispatcher,
           tmp_dir: tmp_dir
         } do
      test_pid = self()

      workflow =
        Runic.Workflow.new()
        |> Runic.Workflow.add(
          Runic.step(
            fn input ->
              send(test_pid, {:task_running, self()})
              receive do: (:release -> input)
            end,
            name: :blocking_step
          )
        )

      %{version: version} = published_version_fixture(scope)
      run = insert_running_run(scope, version, %{compiled_hash: nil})

      Phoenix.PubSub.subscribe(Fizz.PubSub, "workflow_run:#{run.id}")

      pid =
        start_worker!(workflow, run, scope,
          registry: registry,
          task_supervisor: task_supervisor,
          runnable_dispatcher: runnable_dispatcher,
          tmp_dir: tmp_dir
        )

      Worker.run(pid, %{})
      assert_receive {:task_running, task_pid}, 2_000

      # Corrupt the store directory to force checkpoint failure
      File.rm_rf(tmp_dir)

      # Kill the task to trigger fail_and_stop (which will try to checkpoint and fail)
      Process.exit(task_pid, :kill)

      assert_receive {:run_status_changed, %{status: :failed}}, 5_000

      {:ok, db_run} = Workflows.get_run(scope, run.id)
      assert db_run.status == :failed
    end
  end

  describe "terminate/2 safety net" do
    test "worker stopped via GenServer.stop marks run :failed in DB",
         %{
           scope: scope,
           registry: registry,
           task_supervisor: task_supervisor,
           runnable_dispatcher: runnable_dispatcher,
           tmp_dir: tmp_dir
         } do
      test_pid = self()

      workflow =
        Runic.Workflow.new()
        |> Runic.Workflow.add(
          Runic.step(
            fn input ->
              send(test_pid, {:task_running, self()})
              receive do: (:release -> input)
            end,
            name: :blocking_step
          )
        )

      %{version: version} = published_version_fixture(scope)
      run = insert_running_run(scope, version, %{compiled_hash: nil})

      Phoenix.PubSub.subscribe(Fizz.PubSub, "workflow_run:#{run.id}")

      pid =
        start_worker!(workflow, run, scope,
          registry: registry,
          task_supervisor: task_supervisor,
          runnable_dispatcher: runnable_dispatcher,
          tmp_dir: tmp_dir
        )

      Worker.run(pid, %{})
      assert_receive {:task_running, _task_pid}, 2_000

      # GenServer.stop triggers terminate/2 with :normal reason
      GenServer.stop(pid, :shutdown)

      assert {:ok, %{status: :failed}} = Workflows.get_run(scope, run.id)
    end

    test "abnormal worker termination cancels timers and releases the lease",
         %{
           scope: scope,
           registry: registry,
           task_supervisor: task_supervisor,
           runnable_dispatcher: runnable_dispatcher,
           tmp_dir: tmp_dir
         } do
      test_pid = self()

      workflow =
        Runic.Workflow.new()
        |> Runic.Workflow.add(
          Runic.step(
            fn input ->
              send(test_pid, {:task_running, self()})
              receive do: (:release -> input)
            end,
            name: :blocking_step
          )
        )

      %{version: version} = published_version_fixture(scope)
      run = insert_running_run(scope, version, %{compiled_hash: nil})
      timer = insert_timer(run)

      Phoenix.PubSub.subscribe(Fizz.PubSub, "workflow_run:#{run.id}")

      pid =
        start_worker!(workflow, run, scope,
          registry: registry,
          task_supervisor: task_supervisor,
          runnable_dispatcher: runnable_dispatcher,
          tmp_dir: tmp_dir
        )

      Worker.run(pid, %{})
      assert_receive {:task_running, _task_pid}, 2_000

      GenServer.stop(pid, :shutdown)

      assert_receive {:run_status_changed, %{run_id: run_id, status: :failed}}, 5_000
      assert run_id == run.id
      assert {:ok, %{status: :failed}} = Workflows.get_run(scope, run.id)
      assert %{status: :cancelled} = reload_timer(timer)
      assert lease_released?(run.id)
    end
  end

  describe "cancellation from non-running states" do
    test "cancel from :sleeping state -> run :cancelled",
         %{
           scope: scope,
           registry: registry,
           task_supervisor: task_supervisor,
           runnable_dispatcher: runnable_dispatcher,
           tmp_dir: tmp_dir
         } do
      %{version: version} = published_version_fixture(scope, long_running_snapshot_attrs(30_000))
      {:ok, workflow, compiled_hash} = Compiler.compile(version)
      run = insert_running_run(scope, version, %{compiled_hash: compiled_hash})

      pid =
        start_worker!(workflow, run, scope,
          registry: registry,
          task_supervisor: task_supervisor,
          runnable_dispatcher: runnable_dispatcher,
          tmp_dir: tmp_dir
        )

      Worker.run(pid, %{})

      wait_until(fn ->
        case Worker.lookup(run.id, registry: registry) do
          nil -> false
          wpid -> :sys.get_state(wpid).status == :sleeping
        end
      end)

      assert {:ok, %{status: :cancelled}} = Workflows.cancel_run(scope, run.id)
    end

    test "cancel when no worker is running (passivated) -> run :cancelled",
         %{scope: scope} do
      # Simulate a passivated run: create a run in :sleeping status with no active worker
      %{version: version} = published_version_fixture(scope, long_running_snapshot_attrs(30_000))
      now = DateTime.utc_now()

      run =
        %WorkflowRun{}
        |> WorkflowRun.changeset(%{
          user_id: scope.user.id,
          workflow_definition_id: version.workflow_definition_id,
          workflow_definition_version_id: version.id,
          project_id: scope.project.id,
          workos_organization_id: scope.project.workos_organization_id,
          status: :sleeping,
          input: %{},
          last_active_at: now,
          started_at: now
        })
        |> Repo.insert!()

      # No worker is running — cancel should still work
      assert {:ok, %{status: :cancelled}} = Workflows.cancel_run(scope, run.id)
    end
  end

  # --- Shared helpers ---

  defp start_worker!(workflow, run, scope, opts) do
    registry = Keyword.fetch!(opts, :registry)
    runnable_dispatcher = Keyword.fetch!(opts, :runnable_dispatcher)
    tmp_dir = Keyword.fetch!(opts, :tmp_dir)
    fence_token = Keyword.get(opts, :fence_token, 1)

    insert_lease(run.id, fence_token)

    {:ok, store_state} =
      SqliteStore.init(run.id,
        data_dir: tmp_dir,
        org_id: scope.project.workos_organization_id,
        project_id: scope.project.id,
        fence_token: fence_token,
        repo: Repo
      )

    start_supervised!(
      {Worker,
       [
         run_id: run.id,
         workflow: workflow,
         run_context: ContextBuilder.build_run_context(scope, run),
         store: store_state,
         fence_token: fence_token,
         registry: registry,
         runnable_dispatcher: runnable_dispatcher,
         max_concurrency: Keyword.get(opts, :max_concurrency, 2),
         checkpoint_strategy: :every_cycle,
         idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 5_000)
       ]}
    )
  end

  defp insert_running_run(scope, version, attrs) do
    now = DateTime.utc_now()

    %WorkflowRun{}
    |> WorkflowRun.changeset(
      Map.merge(
        %{
          user_id: scope.user.id,
          workflow_definition_id: version.workflow_definition_id,
          workflow_definition_version_id: version.id,
          project_id: scope.project.id,
          workos_organization_id: scope.project.workos_organization_id,
          status: :running,
          input: %{},
          last_active_at: now,
          started_at: now
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp insert_lease(run_id, fence_token) do
    assert {:ok, _result} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               INSERT INTO workflow_run_leases (run_id, owner_node, fence_token, checkpoint_seq, lease_expiry)
               VALUES ($1, $2, $3, 0, NOW() + interval '30 seconds')
               """,
               [Ecto.UUID.dump!(run_id), Atom.to_string(node()), fence_token]
             )
  end

  defp insert_timer(run) do
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

  defp reload_timer(timer), do: Repo.get!(DurableTimer, timer.id)

  defp lease_released?(run_id) do
    assert {:ok, %{rows: [[lease_expiry]]}} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               SELECT lease_expiry
               FROM workflow_run_leases
               WHERE run_id = $1
               """,
               [Ecto.UUID.dump!(run_id)]
             )

    NaiveDateTime.compare(lease_expiry, NaiveDateTime.utc_now()) == :lt
  end

  defp unique_name(name) do
    Module.concat([__MODULE__, "#{name}_#{System.unique_integer([:positive])}"])
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("wait_until timed out")

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      50 -> :ok
    end
  end
end
