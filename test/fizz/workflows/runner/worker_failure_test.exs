defmodule Fizz.Workflows.Runner.WorkerFailureTest do
  use Fizz.DataCase, async: false

  import Fizz.WorkflowsFixtures

  alias Fizz.Workflows
  alias Fizz.Workflows.Compiler
  alias Fizz.Workflows.Runner.Worker
  alias Fizz.Workflows.Runtime.ContextBuilder
  alias Fizz.Workflows.Store.SqliteStore
  alias Fizz.Workflows.WorkflowRun

  require Runic

  setup do
    scope = project_scope_fixture()
    registry = unique_name(:registry)
    task_supervisor = unique_name(:task_supervisor)

    tmp_dir =
      Path.join(System.tmp_dir!(), "fizz-worker-failure-#{System.unique_integer([:positive])}")

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Task.Supervisor, name: task_supervisor})

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    %{
      scope: scope,
      registry: registry,
      task_supervisor: task_supervisor,
      tmp_dir: tmp_dir
    }
  end

  describe "task crash (:DOWN)" do
    test "task crash -> step :failed, run :failed",
         %{scope: scope, registry: registry, task_supervisor: task_supervisor, tmp_dir: tmp_dir} do
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
         %{scope: scope, registry: registry, task_supervisor: task_supervisor, tmp_dir: tmp_dir} do
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

  describe "fail_and_stop/2 broadcasts :step_cancelled for active siblings" do
    test "step fails with concurrent siblings -> causal step :failed, siblings :cancelled, run :failed",
         %{scope: scope, registry: registry, task_supervisor: task_supervisor, tmp_dir: tmp_dir} do
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
         %{scope: scope, registry: registry, task_supervisor: task_supervisor, tmp_dir: tmp_dir} do
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
         %{scope: scope, registry: registry, task_supervisor: task_supervisor, tmp_dir: tmp_dir} do
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
          tmp_dir: tmp_dir
        )

      Worker.run(pid, %{})
      assert_receive {:task_running, _task_pid}, 2_000

      # GenServer.stop triggers terminate/2 with :normal reason
      GenServer.stop(pid, :shutdown)

      assert {:ok, %{status: :failed}} = Workflows.get_run(scope, run.id)
    end
  end

  describe "cancellation from non-running states" do
    test "cancel from :sleeping state -> run :cancelled",
         %{scope: scope, registry: registry, task_supervisor: task_supervisor, tmp_dir: tmp_dir} do
      %{version: version} = published_version_fixture(scope, long_running_snapshot_attrs(30_000))
      {:ok, workflow, compiled_hash} = Compiler.compile(version)
      run = insert_running_run(scope, version, %{compiled_hash: compiled_hash})

      pid =
        start_worker!(workflow, run, scope,
          registry: registry,
          task_supervisor: task_supervisor,
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
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)
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
         task_supervisor: task_supervisor,
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
               VALUES ($1, NULL, $2, 0, NOW() + interval '30 seconds')
               """,
               [Ecto.UUID.dump!(run_id), fence_token]
             )
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
