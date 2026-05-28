defmodule Fizz.Workflows.PassivationSweeperTest.FakeLitestream do
  use GenServer

  @impl true
  def init(_), do: {:ok, :running}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, :running, state}
end

defmodule Fizz.Workflows.PassivationSweeperTest do
  use Fizz.DataCase, async: false

  import Fizz.WorkflowsFixtures

  alias Fizz.Workflows.PassivationSweeper
  alias Fizz.Workflows.Runner.RunnableConsumerSupervisor
  alias Fizz.Workflows.Runner.RunnableDispatcher
  alias Fizz.Workflows.Runner.Worker
  alias Fizz.Workflows.Runtime.ContextBuilder
  alias Fizz.Workflows.Store.{Paths, SqliteStore}
  alias Fizz.Workflows.WorkflowRun

  require Runic

  setup do
    scope = project_scope_fixture()
    %{version: version} = published_version_fixture(scope)

    registry = unique_name(:registry)
    task_supervisor = unique_name(:task_supervisor)

    tmp_dir =
      Path.join(System.tmp_dir!(), "fizz-sweeper-#{System.unique_integer([:positive])}")

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Task.Supervisor, name: task_supervisor})

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    %{
      scope: scope,
      version: version,
      registry: registry,
      task_supervisor: task_supervisor,
      tmp_dir: tmp_dir
    }
  end

  test "idle runs beyond the threshold are passivated", ctx do
    sweeper = start_sweeper!(ctx)
    run = insert_run(ctx.scope, ctx.version, :running, old_time())

    pid = start_idle_worker!(run, ctx)
    ref = Process.monitor(pid)

    assert {:ok, passivated_run_ids} = PassivationSweeper.sweep(server: sweeper)
    assert run.id in passivated_run_ids
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    assert {:ok, %{status: :passivated}} = Fizz.Workflows.get_run(ctx.scope, run.id)
  end

  test "active runs are not passivated", ctx do
    sweeper = start_sweeper!(ctx)
    run = insert_run(ctx.scope, ctx.version, :running, DateTime.utc_now())

    assert {:ok, passivated_run_ids} = PassivationSweeper.sweep(server: sweeper)
    refute run.id in passivated_run_ids
    assert {:ok, %{status: :running}} = Fizz.Workflows.get_run(ctx.scope, run.id)
  end

  test "running workers with active tasks are not passivated by stale activity", ctx do
    test_pid = self()
    dispatcher = start_runnable_dispatcher!(:active_work)

    start_runnable_consumer_supervisor!(
      :active_work_consumer,
      dispatcher,
      ctx.task_supervisor
    )

    sweeper = start_sweeper!(ctx)
    run = insert_run(ctx.scope, ctx.version, :running, old_time())

    workflow =
      Runic.Workflow.new()
      |> Runic.Workflow.add(blocking_step(:long_running_step, test_pid))

    pid = start_worker!(workflow, run, ctx, runnable_dispatcher: dispatcher)
    ref = Process.monitor(pid)

    assert :ok = Worker.run(pid, %{"value" => 1})
    assert_receive {:step_started, :long_running_step, task_pid}, 2_000

    state = :sys.get_state(pid)
    assert map_size(state.active_tasks) == 1

    update_last_active_at(run.id, old_time())

    assert {:ok, passivated_run_ids} = PassivationSweeper.sweep(server: sweeper)
    refute run.id in passivated_run_ids
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 200
    assert {:ok, %{status: :running}} = Fizz.Workflows.get_run(ctx.scope, run.id)

    send(task_pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "running workers with queued work are not passivated by stale activity", ctx do
    dispatcher = start_runnable_dispatcher!(:queued_work)
    sweeper = start_sweeper!(ctx)
    run = insert_run(ctx.scope, ctx.version, :running, old_time())

    workflow =
      Runic.Workflow.new()
      |> Runic.Workflow.add(Runic.step(fn input -> input end, name: :queued_step))

    pid = start_worker!(workflow, run, ctx, runnable_dispatcher: dispatcher)
    ref = Process.monitor(pid)

    assert :ok = Worker.run(pid, %{"value" => 1})

    state = :sys.get_state(pid)
    assert [%{status: :queued}] = Map.values(state.active_tasks)

    update_last_active_at(run.id, old_time())

    assert {:ok, passivated_run_ids} = PassivationSweeper.sweep(server: sweeper)
    refute run.id in passivated_run_ids
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 200
    assert {:ok, %{status: :running}} = Fizz.Workflows.get_run(ctx.scope, run.id)

    assert :ok = Worker.stop(pid, persist: false)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "completed and failed runs are not passivated", ctx do
    sweeper = start_sweeper!(ctx)
    completed_run = insert_run(ctx.scope, ctx.version, :completed, old_time())
    failed_run = insert_run(ctx.scope, ctx.version, :failed, old_time())

    assert {:ok, passivated_run_ids} = PassivationSweeper.sweep(server: sweeper)
    refute completed_run.id in passivated_run_ids
    refute failed_run.id in passivated_run_ids
    assert {:ok, %{status: :completed}} = Fizz.Workflows.get_run(ctx.scope, completed_run.id)
    assert {:ok, %{status: :failed}} = Fizz.Workflows.get_run(ctx.scope, failed_run.id)
  end

  test "runs without a worker and without a checkpoint are not passivated", ctx do
    sweeper = start_sweeper!(ctx)
    run = insert_run(ctx.scope, ctx.version, :sleeping, old_time())

    assert {:ok, passivated_run_ids} = PassivationSweeper.sweep(server: sweeper)
    refute run.id in passivated_run_ids
    assert {:ok, %{status: :sleeping}} = Fizz.Workflows.get_run(ctx.scope, run.id)
  end

  test "runs without a worker can still be passivated when a checkpoint exists", ctx do
    sweeper = start_sweeper!(ctx)
    run = insert_run(ctx.scope, ctx.version, :sleeping, old_time())

    persist_checkpoint!(run, ctx)

    assert {:ok, passivated_run_ids} = PassivationSweeper.sweep(server: sweeper)
    assert run.id in passivated_run_ids
    assert {:ok, %{status: :passivated}} = Fizz.Workflows.get_run(ctx.scope, run.id)
  end

  test "running runs without a worker are not DB-only passivated", ctx do
    sweeper = start_sweeper!(ctx)
    run = insert_run(ctx.scope, ctx.version, :running, old_time())

    persist_checkpoint!(run, ctx)

    assert {:ok, passivated_run_ids} = PassivationSweeper.sweep(server: sweeper)
    refute run.id in passivated_run_ids
    assert {:ok, %{status: :running}} = Fizz.Workflows.get_run(ctx.scope, run.id)
  end

  test "runs without a worker and with an active lease are not DB-only passivated", ctx do
    sweeper = start_sweeper!(ctx)
    run = insert_run(ctx.scope, ctx.version, :sleeping, old_time())

    persist_checkpoint!(run, ctx, active_lease?: true)

    assert {:ok, passivated_run_ids} = PassivationSweeper.sweep(server: sweeper)
    refute run.id in passivated_run_ids
    assert {:ok, %{status: :sleeping}} = Fizz.Workflows.get_run(ctx.scope, run.id)
  end

  test "passivated runs have local SQLite files evicted when litestream is running", ctx do
    fake_litestream = start_fake_litestream!()
    sweeper = start_sweeper!(ctx, litestream_server: fake_litestream)
    run = insert_run(ctx.scope, ctx.version, :running, old_time())

    pid = start_idle_worker!(run, ctx)
    ref = Process.monitor(pid)

    db_path = run_db_path(run, ctx)
    assert File.exists?(db_path)

    assert {:ok, [_]} = PassivationSweeper.sweep(server: sweeper)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    refute File.exists?(db_path)
  end

  test "local files are preserved when litestream is not running", ctx do
    sweeper = start_sweeper!(ctx)
    run = insert_run(ctx.scope, ctx.version, :running, old_time())

    pid = start_idle_worker!(run, ctx)
    ref = Process.monitor(pid)

    db_path = run_db_path(run, ctx)
    assert File.exists?(db_path)

    assert {:ok, [_]} = PassivationSweeper.sweep(server: sweeper)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    assert File.exists?(db_path)
  end

  test "sweep passivates at most the configured batch size", ctx do
    sweeper = start_sweeper!(ctx, batch_size: 2, max_concurrency: 2)

    runs =
      for _index <- 1..3 do
        run = insert_run(ctx.scope, ctx.version, :running, old_time())
        pid = start_idle_worker!(run, ctx)
        {run, Process.monitor(pid)}
      end

    assert {:ok, passivated_run_ids} = PassivationSweeper.sweep(server: sweeper)
    assert length(passivated_run_ids) == 2

    for {run, ref} <- runs, run.id in passivated_run_ids do
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000
    end

    statuses =
      runs
      |> Enum.map(fn {run, _ref} -> Fizz.Workflows.get_run(ctx.scope, run.id) end)
      |> Enum.map(fn {:ok, run} -> run.status end)

    assert Enum.count(statuses, &(&1 == :passivated)) == 2
    assert Enum.count(statuses, &(&1 == :running)) == 1
  end

  test "wal_checkpoint failure preserves local files", ctx do
    fake_litestream = start_fake_litestream!()

    wal_checkpoint = fn db_path ->
      File.write!("#{db_path}-wal", "pending wal")
      File.write!("#{db_path}-shm", "pending shm")
      {:error, :checkpoint_failed}
    end

    sweeper =
      start_sweeper!(ctx,
        litestream_server: fake_litestream,
        wal_checkpoint: wal_checkpoint
      )

    run = insert_run(ctx.scope, ctx.version, :running, old_time())

    pid = start_idle_worker!(run, ctx)
    ref = Process.monitor(pid)

    db_path = run_db_path(run, ctx)
    assert File.exists?(db_path)

    assert {:ok, passivated_run_ids} = PassivationSweeper.sweep(server: sweeper)
    assert run.id in passivated_run_ids
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    assert File.exists?(db_path)
    assert File.read!("#{db_path}-wal") == "pending wal"
    assert File.read!("#{db_path}-shm") == "pending shm"
    assert {:ok, %{status: :passivated}} = Fizz.Workflows.get_run(ctx.scope, run.id)
  end

  defp start_sweeper!(ctx, extra_opts \\ []) do
    name = unique_name(:sweeper)

    start_supervised!(
      {PassivationSweeper,
       Keyword.merge(
         [
           name: name,
           interval_ms: 60_000,
           idle_threshold_ms: 60_000,
           worker_opts: [registry: ctx.registry],
           data_dir: ctx.tmp_dir
         ],
         extra_opts
       )}
    )

    name
  end

  defp start_fake_litestream! do
    name = unique_name(:fake_litestream)

    start_supervised!(%{
      id: name,
      start: {GenServer, :start_link, [__MODULE__.FakeLitestream, [], [name: name]]}
    })

    name
  end

  defp start_runnable_dispatcher!(name) do
    dispatcher = unique_name(name)

    start_supervised!(
      Supervisor.child_spec({RunnableDispatcher, name: dispatcher}, id: dispatcher)
    )

    dispatcher
  end

  defp start_runnable_consumer_supervisor!(name, dispatcher, task_supervisor) do
    consumer_supervisor = unique_name(name)

    start_supervised!(
      Supervisor.child_spec(
        {RunnableConsumerSupervisor,
         name: consumer_supervisor,
         dispatcher: dispatcher,
         task_supervisor: task_supervisor,
         max_concurrency: 1},
        id: consumer_supervisor
      )
    )

    consumer_supervisor
  end

  defp run_db_path(run, ctx) do
    Paths.db_path(
      Path.expand(ctx.tmp_dir),
      run.id,
      ctx.scope.project.workos_organization_id,
      ctx.scope.project.id
    )
  end

  defp start_idle_worker!(run, ctx) do
    workflow = Runic.workflow(steps: [])

    start_worker!(workflow, run, ctx)
  end

  defp start_worker!(workflow, run, ctx, opts \\ []) do
    fence_token = 1

    insert_lease(run.id, fence_token)

    {:ok, store_state} =
      SqliteStore.init(run.id,
        data_dir: ctx.tmp_dir,
        org_id: ctx.scope.project.workos_organization_id,
        project_id: ctx.scope.project.id,
        fence_token: fence_token,
        repo: Repo
      )

    start_supervised!(
      {Worker,
       [
         run_id: run.id,
         workflow: workflow,
         run_context: ContextBuilder.build_run_context(ctx.scope, run),
         store: store_state,
         fence_token: fence_token,
         registry: ctx.registry,
         task_supervisor: ctx.task_supervisor,
         runnable_dispatcher:
           Keyword.get(opts, :runnable_dispatcher, Fizz.Workflows.Runner.RunnableDispatcher),
         checkpoint_strategy: :every_cycle
       ]}
    )
  end

  defp insert_run(scope, version, status, last_active_at) do
    now = DateTime.utc_now()

    %WorkflowRun{}
    |> WorkflowRun.changeset(%{
      user_id: scope.user.id,
      workflow_definition_id: version.workflow_definition_id,
      workflow_definition_version_id: version.id,
      project_id: scope.project.id,
      workos_organization_id: scope.project.workos_organization_id,
      status: status,
      input: %{},
      last_active_at: last_active_at,
      started_at: now,
      completed_at: if(status in [:completed, :failed], do: now)
    })
    |> Repo.insert!()
  end

  defp insert_lease(run_id, fence_token, lease_expiry_sql \\ "NOW() + interval '30 seconds'") do
    assert {:ok, _result} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               INSERT INTO workflow_run_leases (run_id, owner_node, fence_token, checkpoint_seq, lease_expiry)
               VALUES ($1, NULL, $2, 0, #{lease_expiry_sql})
               """,
               [dump_uuid(run_id), fence_token]
             )
  end

  defp update_last_active_at(run_id, value) do
    assert {_count, nil} =
             from(run in WorkflowRun, where: run.id == ^run_id)
             |> Repo.update_all(set: [last_active_at: value])
  end

  defp dump_uuid(run_id), do: Ecto.UUID.dump!(run_id)

  defp old_time do
    DateTime.add(DateTime.utc_now(), -5, :minute)
  end

  defp blocking_step(name, test_pid) do
    Runic.step(
      fn input ->
        send(test_pid, {:step_started, name, self()})

        receive do
          :release -> input
        end
      end,
      name: name
    )
  end

  defp persist_checkpoint!(run, ctx, opts \\ []) do
    fence_token = 1
    insert_lease(run.id, fence_token)

    {:ok, store_state} =
      SqliteStore.init(run.id,
        data_dir: ctx.tmp_dir,
        org_id: ctx.scope.project.workos_organization_id,
        project_id: ctx.scope.project.id,
        fence_token: fence_token,
        repo: Repo
      )

    workflow = Runic.workflow(steps: [])
    :ok = SqliteStore.save(run.id, Runic.Workflow.event_log(workflow), store_state)

    unless Keyword.get(opts, :active_lease?, false) do
      expire_lease(run.id)
    end
  end

  defp expire_lease(run_id) do
    assert {:ok, _result} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               UPDATE workflow_run_leases
               SET lease_expiry = NOW() - interval '1 second'
               WHERE run_id = $1
               """,
               [dump_uuid(run_id)]
             )
  end

  defp unique_name(name) do
    Module.concat([__MODULE__, "#{name}_#{System.unique_integer([:positive])}"])
  end
end
