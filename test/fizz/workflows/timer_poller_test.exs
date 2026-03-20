defmodule Fizz.Workflows.TimerPollerTest do
  use Fizz.DataCase, async: false

  import Fizz.WorkflowsFixtures

  alias Fizz.Workflows
  alias Fizz.Workflows.DurableTimer
  alias Fizz.Workflows.Runner.Worker
  alias Fizz.Workflows.TimerPoller
  alias Fizz.Workflows.WorkflowRun

  setup do
    scope = project_scope_fixture()
    original_workflow_env = Application.get_env(:fizz, Fizz.Workflows, [])

    on_exit(fn ->
      Application.put_env(:fizz, Fizz.Workflows, original_workflow_env)
    end)

    %{scope: scope}
  end

  test "timer created by a workflow run is fired by the poller after fire_at", %{scope: scope} do
    put_workflow_runtime(idle_timeout_ms: 25)

    %{version: version} =
      published_version_fixture(scope, long_running_snapshot_attrs(100))

    poller = unique_name(:poller)

    start_supervised!({TimerPoller, name: poller, interval_ms: 60_000, claim_ttl_ms: 100})

    assert {:ok, run} = Workflows.start_run(scope, version, %{"kind" => "initial"})

    timer =
      eventually(fn ->
        case pending_timers_for_run(run.id) do
          [%DurableTimer{} = timer] -> {:ok, timer}
          _ -> :retry
        end
      end)

    assert timer.status == :pending

    fired_ids =
      eventually(fn ->
        case TimerPoller.poll(server: poller) do
          {:ok, [_ | _] = ids} -> {:ok, ids}
          _ -> :retry
        end
      end)

    assert timer.id in fired_ids

    completed_run =
      eventually(fn ->
        with {:ok, %WorkflowRun{status: :completed} = workflow_run} <-
               Workflows.get_run(scope, run.id) do
          {:ok, workflow_run}
        else
          _ -> :retry
        end
      end)

    assert completed_run.status == :completed
    assert {:ok, %DurableTimer{status: :fired}} = Workflows.get_timer(timer.id)
    assert_worker_shutdown(run.id)
  end

  test "cancelled timers are skipped by the poller", %{scope: scope} do
    put_workflow_runtime(idle_timeout_ms: 25)

    %{version: version} =
      published_version_fixture(scope, long_running_snapshot_attrs(100))

    poller = unique_name(:poller)

    start_supervised!({TimerPoller, name: poller, interval_ms: 60_000, claim_ttl_ms: 100})

    assert {:ok, run} = Workflows.start_run(scope, version, %{"kind" => "cancel-me"})

    timer =
      eventually(fn ->
        case pending_timers_for_run(run.id) do
          [%DurableTimer{} = timer] -> {:ok, timer}
          _ -> :retry
        end
      end)

    assert {:ok, %{status: :cancelled}} = Workflows.cancel_run(scope, run.id)
    assert {:ok, []} = TimerPoller.poll(server: poller)
    assert {:ok, %DurableTimer{status: :cancelled}} = Workflows.get_timer(timer.id)
  end

  test "concurrent pollers claim disjoint timer batches with skip locked", %{scope: scope} do
    runs =
      for _ <- 1..4 do
        insert_run(scope, :completed)
      end

    timers =
      Enum.map(runs, fn run ->
        insert_timer(run, %{
          fire_at: DateTime.add(DateTime.utc_now(), -1, :second),
          status: :pending,
          payload: nil
        })
      end)

    poller_a = unique_name(:poller_a)
    poller_b = unique_name(:poller_b)

    start_supervised!(
      {TimerPoller, name: poller_a, interval_ms: 60_000, batch_size: 2, claimed_by: "poller-a"}
    )

    start_supervised!(
      {TimerPoller, name: poller_b, interval_ms: 60_000, batch_size: 2, claimed_by: "poller-b"}
    )

    task_a = Task.async(fn -> TimerPoller.poll(server: poller_a) end)
    task_b = Task.async(fn -> TimerPoller.poll(server: poller_b) end)

    assert {:ok, claimed_a} = Task.await(task_a)
    assert {:ok, claimed_b} = Task.await(task_b)

    assert MapSet.disjoint?(MapSet.new(claimed_a), MapSet.new(claimed_b))

    claimed_ids = MapSet.new(claimed_a ++ claimed_b)
    expected_ids = MapSet.new(Enum.map(timers, & &1.id))

    assert claimed_ids == expected_ids

    assert Enum.all?(reload_timers(timers), &(&1.status == :fired))
  end

  test "stale firing timers are reset to pending after claim ttl expiry", %{scope: scope} do
    run = insert_run(scope, :sleeping)

    stale_timer =
      insert_timer(run, %{
        fire_at: DateTime.add(DateTime.utc_now(), 1, :minute),
        status: :firing,
        claimed_at: DateTime.add(DateTime.utc_now(), -5, :minute),
        claimed_by: "dead-poller",
        payload: nil
      })

    poller = unique_name(:poller)

    start_supervised!(
      {TimerPoller,
       name: poller, interval_ms: 60_000, claim_ttl_ms: 1_000, claimed_by: "recovery"}
    )

    assert {:ok, []} = TimerPoller.poll(server: poller)

    assert {:ok, %DurableTimer{} = recovered} = Workflows.get_timer(stale_timer.id)
    assert recovered.status == :pending
    assert recovered.claimed_at == nil
    assert recovered.claimed_by == nil
  end

  defp put_workflow_runtime(opts) do
    current = Application.get_env(:fizz, Fizz.Workflows, [])
    Application.put_env(:fizz, Fizz.Workflows, Keyword.merge(current, opts))
  end

  defp pending_timers_for_run(run_id) do
    DurableTimer
    |> where([timer], timer.run_id == ^run_id and timer.status == :pending)
    |> order_by([timer], asc: timer.inserted_at)
    |> Repo.all()
  end

  defp insert_run(scope, status) do
    now = DateTime.utc_now()
    %{version: version} = published_version_fixture(scope)

    %WorkflowRun{}
    |> WorkflowRun.changeset(%{
      workflow_definition_id: version.workflow_definition_id,
      workflow_definition_version_id: version.id,
      project_id: scope.project.id,
      workos_organization_id: scope.project.workos_organization_id,
      status: status,
      input: %{},
      last_active_at: now,
      started_at: now,
      completed_at: if(status == :completed, do: now)
    })
    |> Repo.insert!()
  end

  defp insert_timer(run, attrs) do
    defaults = %{
      run_id: run.id,
      step_id: "wait-step",
      timer_name: "wait-step",
      project_id: run.project_id,
      workos_organization_id: run.workos_organization_id,
      fire_at: DateTime.utc_now(),
      status: :pending,
      payload: %{},
      claimed_at: nil,
      claimed_by: nil
    }

    %DurableTimer{}
    |> DurableTimer.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp reload_timers(timers) do
    Enum.map(timers, &Repo.get!(DurableTimer, &1.id))
  end

  defp eventually(fun, attempts \\ 100)

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

  defp unique_name(name) do
    Module.concat([__MODULE__, "#{name}_#{System.unique_integer([:positive])}"])
  end

  defp assert_worker_shutdown(run_id) do
    case Worker.lookup(run_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end
  end
end
