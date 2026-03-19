defmodule Fizz.Workflows.PassivationSweeperTest do
  use Fizz.DataCase, async: false

  import Fizz.WorkflowsFixtures

  alias Fizz.Workflows.PassivationSweeper
  alias Fizz.Workflows.Runner.Worker
  alias Fizz.Workflows.Runtime.ContextBuilder
  alias Fizz.Workflows.Store.SqliteStore
  alias Fizz.Workflows.WorkflowRun

  require Runic

  setup do
    scope = project_scope_fixture()
    %{version: version} = published_version_fixture(scope)

    registry = unique_name(:registry)
    task_supervisor = unique_name(:task_supervisor)
    sweeper = unique_name(:sweeper)

    tmp_dir =
      Path.join(System.tmp_dir!(), "fizz-sweeper-#{System.unique_integer([:positive])}")

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Task.Supervisor, name: task_supervisor})

    start_supervised!(
      {PassivationSweeper,
       name: sweeper,
       interval_ms: 60_000,
       idle_threshold_ms: 60_000,
       worker_opts: [registry: registry]}
    )

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    %{
      scope: scope,
      version: version,
      registry: registry,
      task_supervisor: task_supervisor,
      sweeper: sweeper,
      tmp_dir: tmp_dir
    }
  end

  test "idle runs beyond the threshold are passivated", %{
    scope: scope,
    version: version,
    registry: registry,
    task_supervisor: task_supervisor,
    sweeper: sweeper,
    tmp_dir: tmp_dir
  } do
    run = insert_run(scope, version, :running, old_time())

    pid =
      start_idle_worker!(
        run,
        scope,
        registry: registry,
        task_supervisor: task_supervisor,
        tmp_dir: tmp_dir
      )

    ref = Process.monitor(pid)

    assert {:ok, passivated_run_ids} = PassivationSweeper.sweep(server: sweeper)
    assert passivated_run_ids == [run.id]
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    assert {:ok, %{status: :passivated}} = Fizz.Workflows.get_run(scope, run.id)
  end

  test "active runs are not passivated", %{scope: scope, version: version, sweeper: sweeper} do
    run = insert_run(scope, version, :running, DateTime.utc_now())

    assert {:ok, []} = PassivationSweeper.sweep(server: sweeper)
    assert {:ok, %{status: :running}} = Fizz.Workflows.get_run(scope, run.id)
  end

  test "completed and failed runs are not passivated", %{
    scope: scope,
    version: version,
    sweeper: sweeper
  } do
    completed_run = insert_run(scope, version, :completed, old_time())
    failed_run = insert_run(scope, version, :failed, old_time())

    assert {:ok, []} = PassivationSweeper.sweep(server: sweeper)
    assert {:ok, %{status: :completed}} = Fizz.Workflows.get_run(scope, completed_run.id)
    assert {:ok, %{status: :failed}} = Fizz.Workflows.get_run(scope, failed_run.id)
  end

  defp start_idle_worker!(run, scope, opts) do
    registry = Keyword.fetch!(opts, :registry)
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)
    tmp_dir = Keyword.fetch!(opts, :tmp_dir)
    fence_token = 1

    insert_lease(run.id, fence_token)

    {:ok, store_state} =
      SqliteStore.init(run.id,
        data_dir: tmp_dir,
        org_id: scope.project.workos_organization_id,
        project_id: scope.project.id,
        fence_token: fence_token,
        repo: Repo
      )

    workflow = Runic.workflow(steps: [])

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

  defp unique_name(name) do
    Module.concat([__MODULE__, "#{name}_#{System.unique_integer([:positive])}"])
  end
end
