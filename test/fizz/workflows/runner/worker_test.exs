defmodule Fizz.Workflows.Runner.WorkerTest do
  use Fizz.DataCase, async: false

  import Fizz.WorkflowsFixtures

  alias Fizz.Workflows.Compiler
  alias Fizz.Workflows.Runner.RunnableConsumerSupervisor
  alias Fizz.Workflows.Runner.RunnableDispatcher
  alias Fizz.Workflows.Runner.Worker
  alias Fizz.Workflows.Runtime.ContextBuilder
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
      Path.join(System.tmp_dir!(), "fizz-worker-#{System.unique_integer([:positive])}")

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

  test "starts with a compiled workflow and runs to completion", %{
    scope: scope,
    registry: registry,
    task_supervisor: task_supervisor,
    runnable_dispatcher: runnable_dispatcher,
    tmp_dir: tmp_dir
  } do
    %{version: version} = published_version_fixture(scope)
    {:ok, workflow, compiled_hash} = Compiler.compile(version)

    run =
      insert_running_run(scope, version, %{
        compiled_hash: compiled_hash,
        last_active_at: old_time()
      })

    pid =
      start_worker!(
        workflow,
        run,
        scope,
        registry: registry,
        task_supervisor: task_supervisor,
        runnable_dispatcher: runnable_dispatcher,
        tmp_dir: tmp_dir
      )

    assert :ok = Worker.run(pid, %{"name" => "Ada"})

    assert %{status: :completed} = wait_for_run_status(scope, run.id, registry)
    cleanup_worker(run.id, registry)

    assert {:ok, completed_run} = Fizz.Workflows.get_run(scope, run.id)
    assert completed_run.status == :completed
    assert completed_run.output != nil
  end

  test "bounded event delivery times out before a suspended worker accepts the event", %{
    scope: scope,
    registry: registry,
    task_supervisor: task_supervisor,
    runnable_dispatcher: runnable_dispatcher,
    tmp_dir: tmp_dir
  } do
    workflow =
      Runic.Workflow.new()
      |> Runic.Workflow.add(blocking_step(:bounded_delivery, self()))

    %{version: version} = published_version_fixture(scope)
    run = insert_running_run(scope, version, %{compiled_hash: nil})

    pid =
      start_worker!(
        workflow,
        run,
        scope,
        registry: registry,
        task_supervisor: task_supervisor,
        runnable_dispatcher: runnable_dispatcher,
        tmp_dir: tmp_dir
      )

    :ok = :sys.suspend(pid)

    try do
      assert {:error, :timeout} =
               Worker.deliver_event(pid, {:input, %{"kind" => "late"}}, timeout: 10)

      :ok = :sys.resume(pid)

      refute_receive {:step_started, :bounded_delivery, _pid}, 200
    after
      try do
        :sys.resume(pid)
      catch
        :exit, _reason -> :ok
      end

      cleanup_worker(run.id, registry)
    end
  end

  test "updates last_active_at on step completion", %{
    scope: scope,
    registry: registry,
    task_supervisor: task_supervisor,
    runnable_dispatcher: runnable_dispatcher,
    tmp_dir: tmp_dir
  } do
    %{version: version} = published_version_fixture(scope)
    {:ok, workflow, compiled_hash} = Compiler.compile(version)
    last_active_at = old_time()

    run =
      insert_running_run(scope, version, %{
        compiled_hash: compiled_hash,
        last_active_at: last_active_at
      })

    pid =
      start_worker!(
        workflow,
        run,
        scope,
        registry: registry,
        task_supervisor: task_supervisor,
        runnable_dispatcher: runnable_dispatcher,
        tmp_dir: tmp_dir
      )

    assert :ok = Worker.run(pid, %{"name" => "Grace"})

    assert %{status: :completed} = wait_for_run_status(scope, run.id, registry)
    cleanup_worker(run.id, registry)

    assert {:ok, completed_run} = Fizz.Workflows.get_run(scope, run.id)
    assert DateTime.compare(completed_run.last_active_at, last_active_at) == :gt
  end

  test "broadcasts step lifecycle and run status events", %{
    scope: scope,
    registry: registry,
    task_supervisor: task_supervisor,
    runnable_dispatcher: runnable_dispatcher,
    tmp_dir: tmp_dir
  } do
    %{version: version} = published_version_fixture(scope)
    {:ok, workflow, compiled_hash} = Compiler.compile(version)
    run = insert_running_run(scope, version, %{compiled_hash: compiled_hash})
    run_id = run.id

    :ok = Phoenix.PubSub.subscribe(Fizz.PubSub, "workflow_run:#{run_id}")

    pid =
      start_worker!(
        workflow,
        run,
        scope,
        registry: registry,
        task_supervisor: task_supervisor,
        runnable_dispatcher: runnable_dispatcher,
        tmp_dir: tmp_dir
      )

    assert :ok = Worker.run(pid, %{"name" => "Toni"})

    assert_receive {:run_status_changed,
                    %{run_id: ^run_id, status: :running, timestamp: %DateTime{}}},
                   2_000

    assert_receive {:step_started,
                    %{
                      run_id: ^run_id,
                      step_id: step_id,
                      started_at: %DateTime{},
                      attempt: 0,
                      input_summary: input_summary
                    } = started_payload},
                   2_000

    assert is_binary(step_id)
    assert is_binary(input_summary)
    refute Map.has_key?(started_payload, :input)

    assert_receive {:step_completed,
                    %{
                      run_id: ^run_id,
                      step_id: ^step_id,
                      completed_at: %DateTime{},
                      duration_us: duration_us,
                      output_item_count: output_item_count,
                      output_summary: output_summary
                    } = completed_payload},
                   2_000

    assert is_integer(duration_us)
    assert output_item_count == 1
    assert is_binary(output_summary)
    refute Map.has_key?(completed_payload, :input)
    refute Map.has_key?(completed_payload, :output)

    assert_receive {:run_status_changed,
                    %{run_id: ^run_id, status: :completed, timestamp: %DateTime{}}},
                   2_000

    assert %{status: :completed} = wait_for_run_status(scope, run_id, registry)
    cleanup_worker(run_id, registry)
  end

  test "step lifecycle payloads summarize large values", %{
    scope: scope,
    registry: registry,
    task_supervisor: task_supervisor,
    runnable_dispatcher: runnable_dispatcher,
    tmp_dir: tmp_dir
  } do
    workflow =
      Runic.Workflow.new()
      |> Runic.Workflow.add(
        Runic.step(fn _input -> Enum.to_list(1..5_000) end, name: :large_output)
      )

    %{version: version} = published_version_fixture(scope)
    run = insert_running_run(scope, version, %{compiled_hash: nil})
    run_id = run.id

    :ok = Phoenix.PubSub.subscribe(Fizz.PubSub, "workflow_run:#{run_id}")

    pid =
      start_worker!(
        workflow,
        run,
        scope,
        registry: registry,
        task_supervisor: task_supervisor,
        runnable_dispatcher: runnable_dispatcher,
        tmp_dir: tmp_dir
      )

    assert :ok = Worker.run(pid, %{"large" => Enum.to_list(1..5_000)})

    assert_receive {:step_started, %{input_summary: input_summary} = started_payload}, 2_000
    assert byte_size(input_summary) <= 1_027
    refute Map.has_key?(started_payload, :input)

    assert_receive {:step_completed, %{output_summary: output_summary} = completed_payload}, 2_000
    assert byte_size(output_summary) <= 1_027
    refute Map.has_key?(completed_payload, :input)
    refute Map.has_key?(completed_payload, :output)
    refute String.contains?(output_summary, "5000")

    assert %{status: :completed} = wait_for_run_status(scope, run_id, registry)
    cleanup_worker(run_id, registry)
  end

  test "transitions the run to completed when the workflow is satisfied", %{
    scope: scope,
    registry: registry,
    task_supervisor: task_supervisor,
    runnable_dispatcher: runnable_dispatcher,
    tmp_dir: tmp_dir
  } do
    %{version: version} = published_version_fixture(scope)
    {:ok, workflow, compiled_hash} = Compiler.compile(version)
    run = insert_running_run(scope, version, %{compiled_hash: compiled_hash})

    pid =
      start_worker!(
        workflow,
        run,
        scope,
        registry: registry,
        task_supervisor: task_supervisor,
        runnable_dispatcher: runnable_dispatcher,
        tmp_dir: tmp_dir
      )

    assert :ok = Worker.run(pid, %{"name" => "Lin"})
    assert %{status: :completed} = wait_for_run_status(scope, run.id, registry)
    cleanup_worker(run.id, registry)
    assert {:ok, %{status: :completed}} = Fizz.Workflows.get_run(scope, run.id)
  end

  test "defers dispatch when max_concurrency is reached", %{
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
            send(test_pid, {:step_started, :one, self()})

            receive do
              :release -> input
            end
          end,
          name: :one
        )
      )
      |> Runic.Workflow.add(
        Runic.step(
          fn input ->
            send(test_pid, {:step_started, :two, self()})

            receive do
              :release -> input
            end
          end,
          name: :two
        ),
        to: :one
      )

    %{version: version} = published_version_fixture(scope)
    run = insert_running_run(scope, version, %{})

    pid =
      start_worker!(
        workflow,
        run,
        scope,
        registry: registry,
        task_supervisor: task_supervisor,
        runnable_dispatcher: runnable_dispatcher,
        tmp_dir: tmp_dir,
        max_concurrency: 1
      )

    assert :ok = Worker.run(pid, %{"value" => 1})

    assert_receive {:step_started, :one, first_task_pid}, 2_000

    state = :sys.get_state(pid)
    assert map_size(state.active_tasks) == 1
    refute_receive {:step_started, :two, _pid}, 100

    send(first_task_pid, :release)

    assert_receive {:step_started, :two, second_task_pid}, 2_000
    send(second_task_pid, :release)

    assert %{status: :completed} = wait_for_run_status(scope, run.id, registry)
    cleanup_worker(run.id, registry)
  end

  test "global saturation defers runnable execution without crashing", %{
    scope: scope,
    registry: registry,
    task_supervisor: task_supervisor,
    tmp_dir: tmp_dir
  } do
    test_pid = self()
    limited_dispatcher = unique_name(:limited_runnable_dispatcher)
    limited_consumer_supervisor = unique_name(:limited_runnable_consumer_supervisor)

    start_supervised!(
      Supervisor.child_spec({RunnableDispatcher, name: limited_dispatcher},
        id: limited_dispatcher
      )
    )

    start_supervised!(
      Supervisor.child_spec(
        {RunnableConsumerSupervisor,
         name: limited_consumer_supervisor,
         dispatcher: limited_dispatcher,
         task_supervisor: task_supervisor,
         max_concurrency: 1},
        id: limited_consumer_supervisor
      )
    )

    workflow =
      Runic.Workflow.new()
      |> Runic.Workflow.add(blocking_step(:one, test_pid))
      |> Runic.Workflow.add(blocking_step(:two, test_pid))

    %{version: version} = published_version_fixture(scope)
    run = insert_running_run(scope, version, %{})

    pid =
      start_worker!(
        workflow,
        run,
        scope,
        registry: registry,
        task_supervisor: task_supervisor,
        runnable_dispatcher: limited_dispatcher,
        tmp_dir: tmp_dir,
        max_concurrency: 2
      )

    assert :ok = Worker.run(pid, %{"value" => 1})

    assert_receive {:step_started, first_step, first_task_pid}, 2_000
    refute_receive {:step_started, _second_step, _second_task_pid}, 100

    send(first_task_pid, :release)

    assert_receive {:step_started, second_step, second_task_pid}, 2_000
    assert first_step != second_step

    send(second_task_pid, :release)

    assert %{status: :completed} = wait_for_run_status(scope, run.id, registry)
    cleanup_worker(run.id, registry)
  end

  test "multiple runs share global runnable capacity fairly", %{
    scope: scope,
    registry: registry,
    task_supervisor: task_supervisor,
    tmp_dir: tmp_dir
  } do
    test_pid = self()
    limited_dispatcher = unique_name(:fair_runnable_dispatcher)
    limited_consumer_supervisor = unique_name(:fair_runnable_consumer_supervisor)

    start_supervised!(
      Supervisor.child_spec({RunnableDispatcher, name: limited_dispatcher},
        id: limited_dispatcher
      )
    )

    start_supervised!(
      Supervisor.child_spec(
        {RunnableConsumerSupervisor,
         name: limited_consumer_supervisor,
         dispatcher: limited_dispatcher,
         task_supervisor: task_supervisor,
         max_concurrency: 1},
        id: limited_consumer_supervisor
      )
    )

    %{version: version} = published_version_fixture(scope)
    run_a = insert_running_run(scope, version, %{})
    run_b = insert_running_run(scope, version, %{})
    run_a_id = run_a.id
    run_b_id = run_b.id

    workflow_a =
      Runic.Workflow.new()
      |> Runic.Workflow.add(blocking_step(:a_one, test_pid, {run_a_id, :one}))
      |> Runic.Workflow.add(blocking_step(:a_two, test_pid, {run_a_id, :two}))

    workflow_b =
      Runic.Workflow.new()
      |> Runic.Workflow.add(blocking_step(:b_one, test_pid, {run_b_id, :one}))

    pid_a =
      start_worker!(
        workflow_a,
        run_a,
        scope,
        registry: registry,
        task_supervisor: task_supervisor,
        runnable_dispatcher: limited_dispatcher,
        tmp_dir: tmp_dir,
        max_concurrency: 2
      )

    pid_b =
      start_worker!(
        workflow_b,
        run_b,
        scope,
        registry: registry,
        task_supervisor: task_supervisor,
        runnable_dispatcher: limited_dispatcher,
        tmp_dir: tmp_dir,
        max_concurrency: 1
      )

    assert :ok = Worker.run(pid_a, %{"value" => "a"})
    assert_receive {:step_started, {^run_a_id, _first_step}, first_task_pid}, 2_000

    assert :ok = Worker.run(pid_b, %{"value" => "b"})
    refute_receive {:step_started, {^run_b_id, :one}, _pid}, 100

    send(first_task_pid, :release)

    assert_receive {:step_started, next_label, run_b_task_pid}, 2_000
    assert next_label == {run_b_id, :one}

    send(run_b_task_pid, :release)

    assert_receive {:step_started, final_label, run_a_task_pid}, 2_000
    assert elem(final_label, 0) == run_a_id

    send(run_a_task_pid, :release)

    assert %{status: :completed} = wait_for_run_status(scope, run_a_id, registry)
    assert %{status: :completed} = wait_for_run_status(scope, run_b_id, registry)
    cleanup_worker(run_a_id, registry)
    cleanup_worker(run_b_id, registry)
  end

  test "worker shutdown cancels running work and drops queued work", %{
    scope: scope,
    registry: registry,
    task_supervisor: task_supervisor,
    tmp_dir: tmp_dir
  } do
    test_pid = self()
    limited_dispatcher = unique_name(:shutdown_runnable_dispatcher)
    limited_consumer_supervisor = unique_name(:shutdown_runnable_consumer_supervisor)

    start_supervised!(
      Supervisor.child_spec({RunnableDispatcher, name: limited_dispatcher},
        id: limited_dispatcher
      )
    )

    start_supervised!(
      Supervisor.child_spec(
        {RunnableConsumerSupervisor,
         name: limited_consumer_supervisor,
         dispatcher: limited_dispatcher,
         task_supervisor: task_supervisor,
         max_concurrency: 1},
        id: limited_consumer_supervisor
      )
    )

    workflow =
      Runic.Workflow.new()
      |> Runic.Workflow.add(blocking_step(:one, test_pid))
      |> Runic.Workflow.add(blocking_step(:two, test_pid))

    %{version: version} = published_version_fixture(scope)
    run = insert_running_run(scope, version, %{})

    pid =
      start_worker!(
        workflow,
        run,
        scope,
        registry: registry,
        task_supervisor: task_supervisor,
        runnable_dispatcher: limited_dispatcher,
        tmp_dir: tmp_dir,
        max_concurrency: 2
      )

    assert :ok = Worker.run(pid, %{"value" => 1})
    assert_receive {:step_started, :one, first_task_pid}, 2_000

    worker_ref = Process.monitor(pid)
    task_ref = Process.monitor(first_task_pid)

    assert :ok = Worker.stop(pid, persist: false)
    assert_receive {:DOWN, ^worker_ref, :process, ^pid, _reason}, 2_000
    assert_receive {:DOWN, ^task_ref, :process, ^first_task_pid, _reason}, 2_000
    refute_receive {:step_started, :two, _pid}, 200
  end

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
         idle_timeout_ms: 5_000
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
               [dump_uuid(run_id), fence_token]
             )
  end

  defp dump_uuid(run_id), do: Ecto.UUID.dump!(run_id)

  defp old_time do
    DateTime.add(DateTime.utc_now(), -10, :minute)
  end

  defp blocking_step(name, test_pid), do: blocking_step(name, test_pid, name)

  defp blocking_step(name, test_pid, label) do
    Runic.step(
      fn input ->
        send(test_pid, {:step_started, label, self()})

        receive do
          :release -> input
        end
      end,
      name: name
    )
  end

  defp unique_name(name) do
    Module.concat([__MODULE__, "#{name}_#{System.unique_integer([:positive])}"])
  end

  defp wait_for_run_status(scope, run_id, registry, attempts \\ 100)

  defp wait_for_run_status(scope, run_id, registry, attempts) when attempts > 0 do
    case Fizz.Workflows.get_run(scope, run_id) do
      {:ok, %{status: :completed} = run} ->
        run

      _ ->
        receive do
        after
          20 -> wait_for_run_status(scope, run_id, registry, attempts - 1)
        end
    end
  end

  defp wait_for_run_status(_scope, run_id, registry, 0) do
    case Worker.lookup(run_id, registry: registry) do
      nil -> :ok
      _pid -> :ok
    end

    flunk("run did not reach completed status")
  end

  defp cleanup_worker(run_id, registry) do
    case Worker.lookup(run_id, registry: registry) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} ->
            :ok
        after
          0 ->
            try do
              Worker.stop(pid, persist: false)
            catch
              :exit, _reason -> :ok
            end

            assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
        end
    end
  end
end
