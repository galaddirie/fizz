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

  test "wal_checkpoint failure does not block passivation", ctx do
    fake_litestream = start_fake_litestream!()
    sweeper = start_sweeper!(ctx, litestream_server: fake_litestream)
    run = insert_run(ctx.scope, ctx.version, :running, old_time())

    pid = start_idle_worker!(run, ctx)
    ref = Process.monitor(pid)

    # Pre-delete the file so wal_checkpoint will fail
    db_path = run_db_path(run, ctx)
    File.rm(db_path)

    assert {:ok, passivated_run_ids} = PassivationSweeper.sweep(server: sweeper)
    assert run.id in passivated_run_ids
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

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

  defp run_db_path(run, ctx) do
    Paths.db_path(
      Path.expand(ctx.tmp_dir),
      run.id,
      ctx.scope.project.workos_organization_id,
      ctx.scope.project.id
    )
  end

  defp start_idle_worker!(run, ctx) do
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
         checkpoint_strategy: :every_cycle
       ]}
    )
  end

  defp insert_run(scope, version, status, last_active_at) do
    now = DateTime.utc_now()

    %WorkflowRun{}
    |> WorkflowRun.changeset(%{
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
    DateTime.add(DateTime.utc_now(), -5, :minute)
  end

  defp persist_checkpoint!(run, ctx) do
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
  end

  defp unique_name(name) do
    Module.concat([__MODULE__, "#{name}_#{System.unique_integer([:positive])}"])
  end
end
