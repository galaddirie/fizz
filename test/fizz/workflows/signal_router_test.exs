defmodule Fizz.Workflows.SignalRouterTest do
  use Fizz.DataCase, async: false

  import Fizz.WorkflowsFixtures

  alias Fizz.Workflows
  alias Fizz.Workflows.DurableTimer
  alias Fizz.Workflows.PassivationSweeper
  alias Fizz.Workflows.Runner.Worker
  alias Fizz.Workflows.SignalInbox
  alias Fizz.Workflows.SignalRouter
  alias Fizz.Workflows.WorkflowRun

  setup do
    scope = project_scope_fixture()
    original_workflow_env = Application.get_env(:fizz, Fizz.Workflows, [])

    on_exit(fn ->
      Application.put_env(:fizz, Fizz.Workflows, original_workflow_env)
    end)

    %{scope: scope}
  end

  test "accepts a signal into the inbox", %{scope: scope} do
    run = insert_run(scope, :running)

    assert {:ok, %SignalInbox{} = signal} =
             SignalRouter.accept_signal(run.id, "sig-1", "poke", %{"kind" => "test"})

    assert signal.run_id == run.id
    assert signal.signal_id == "sig-1"
    assert signal.status == :pending
    assert signal_count(run.id, "sig-1") == 1
  end

  test "duplicate (run_id, signal_id) collapses to one record", %{scope: scope} do
    run = insert_run(scope, :running)

    assert {:ok, %SignalInbox{id: first_id}} =
             SignalRouter.accept_signal(run.id, "sig-1", "poke", %{"kind" => "test"})

    assert {:ok, %SignalInbox{id: second_id}} =
             SignalRouter.accept_signal(run.id, "sig-1", "poke", %{"kind" => "test"})

    assert first_id == second_id
    assert signal_count(run.id, "sig-1") == 1
  end

  test "same signal_id on different runs is accepted independently", %{scope: scope} do
    run_a = insert_run(scope, :running)
    run_b = insert_run(scope, :running)

    assert {:ok, %SignalInbox{run_id: run_a_id}} =
             SignalRouter.accept_signal(run_a.id, "shared-id", "poke", %{"run" => "a"})

    assert {:ok, %SignalInbox{run_id: run_b_id}} =
             SignalRouter.accept_signal(run_b.id, "shared-id", "poke", %{"run" => "b"})

    assert run_a_id == run_a.id
    assert run_b_id == run_b.id
    assert signal_count(run_a.id, "shared-id") == 1
    assert signal_count(run_b.id, "shared-id") == 1
  end

  test "signal to a terminal run is recorded but skipped", %{scope: scope} do
    run = insert_run(scope, :completed)
    router = unique_name(:router)

    start_supervised!({SignalRouter, name: router, interval_ms: 60_000})

    assert {:ok, %SignalInbox{} = signal} =
             SignalRouter.accept_signal(run.id, "sig-terminal", "poke", %{"kind" => "terminal"},
               server: router
             )

    assert signal.status == :skipped
  end

  test "different signal_id values with the same payload remain distinct", %{scope: scope} do
    run = insert_run(scope, :running)

    assert {:ok, %SignalInbox{id: first_id}} =
             SignalRouter.accept_signal(run.id, "sig-a", "poke", %{"kind" => "same"})

    assert {:ok, %SignalInbox{id: second_id}} =
             SignalRouter.accept_signal(run.id, "sig-b", "poke", %{"kind" => "same"})

    assert first_id != second_id
    assert signal_count_for_run(run.id) == 2
  end

  test "external signal delivered to a running workflow triggers a step", %{scope: scope} do
    put_workflow_runtime(idle_timeout_ms: 1_000)

    %{version: version} =
      published_version_fixture(scope, long_running_snapshot_attrs(100))

    assert {:ok, run} = Workflows.start_run(scope, version, %{"kind" => "initial"})
    router = unique_name(:router)

    start_supervised!({SignalRouter, name: router, interval_ms: 60_000})

    _timer =
      eventually(fn ->
        case pending_timers(run.id) do
          [_ | _] -> {:ok, :ready}
          _ -> :retry
        end
      end)

    assert {:ok, %SignalInbox{id: signal_row_id}} =
             SignalRouter.accept_signal(run.id, "sig-running", "poke", %{"kind" => "signal"},
               server: router
             )

    delivered_signal =
      eventually(fn ->
        case Workflows.get_signal(signal_row_id) do
          {:ok, %SignalInbox{status: :delivered} = signal} -> {:ok, signal}
          _ -> :retry
        end
      end)

    assert delivered_signal.status == :delivered

    completed_run =
      eventually(fn ->
        with {:ok, %WorkflowRun{status: :completed} = workflow_run} <-
               Workflows.get_run(scope, run.id) do
          {:ok, workflow_run}
        else
          _ -> :retry
        end
      end)

    outputs = completed_run.output["value"]
    assert is_list(outputs)

    delivered_outputs =
      Enum.filter(outputs, fn
        %{"type" => "signal", "signal_id" => "sig-running"} -> true
        _ -> false
      end)

    assert length(delivered_outputs) >= 1
    assert_worker_shutdown(run.id)
  end

  test "accepting a signal without a router leaves delivery to drain", %{scope: scope} do
    put_workflow_runtime(idle_timeout_ms: 1_000)

    %{version: version} =
      published_version_fixture(scope, long_running_snapshot_attrs(60_000))

    assert {:ok, run} = Workflows.start_run(scope, version, %{"kind" => "initial"})

    _timer =
      eventually(fn ->
        case pending_timers(run.id) do
          [_ | _] -> {:ok, :ready}
          _ -> :retry
        end
      end)

    assert {:ok, %SignalInbox{id: signal_row_id, status: :pending}} =
             SignalRouter.accept_signal(run.id, "sig-durable", "poke", %{"kind" => "signal"})

    assert {:ok, %SignalInbox{status: :pending}} = Workflows.get_signal(signal_row_id)

    router = unique_name(:router)
    start_supervised!({SignalRouter, name: router, interval_ms: 60_000})

    assert {:ok, [^signal_row_id]} = SignalRouter.drain(server: router)

    assert eventually(fn ->
             case Workflows.get_signal(signal_row_id) do
               {:ok, %SignalInbox{status: :delivered} = signal} -> {:ok, signal}
               _ -> :retry
             end
           end)

    assert {:ok, _cancelled_run} = Workflows.cancel_run(scope, run.id)
  end

  test "delivery timeout releases a signal claim before worker acceptance", %{scope: scope} do
    put_workflow_runtime(idle_timeout_ms: 1_000)

    %{version: version} =
      published_version_fixture(scope, long_running_snapshot_attrs(60_000))

    router = unique_name(:router)

    start_supervised!(
      {SignalRouter,
       name: router, interval_ms: 60_000, claim_ttl_ms: 60_000, delivery_timeout_ms: 10}
    )

    assert {:ok, run} = Workflows.start_run(scope, version, %{"kind" => "initial"})

    _timer =
      eventually(fn ->
        case pending_timers(run.id) do
          [_ | _] -> {:ok, :ready}
          _ -> :retry
        end
      end)

    worker_pid =
      eventually(fn ->
        case Worker.lookup(run.id) do
          nil -> :retry
          pid -> {:ok, pid}
        end
      end)

    assert {:ok, %SignalInbox{} = signal} =
             Workflows.create_signal_inbox(run.id, "sig-timeout", "poke", %{"kind" => "signal"})

    :ok = :sys.suspend(worker_pid)

    try do
      assert {:ok, []} = SignalRouter.drain(server: router)

      assert {:ok, %SignalInbox{} = released_signal} = Workflows.get_signal(signal.id)
      assert released_signal.status == :pending
      assert released_signal.claimed_at == nil
      assert released_signal.claimed_by == nil

      :ok = :sys.resume(worker_pid)
      _ = :sys.get_state(worker_pid)

      assert {:ok, %SignalInbox{} = pending_signal} = Workflows.get_signal(signal.id)
      assert pending_signal.status == :pending
    after
      try do
        :sys.resume(worker_pid)
      catch
        :exit, _reason -> :ok
      end

      try do
        Workflows.cancel_run(scope, run.id)
      catch
        :exit, _reason -> :ok
      end

      assert_worker_shutdown(run.id)
    end
  end

  test "signal to a passivated workflow wakes the worker", %{scope: scope} do
    put_workflow_runtime(idle_timeout_ms: 25)

    %{version: version} =
      published_version_fixture(scope, long_running_snapshot_attrs(200))

    sweeper = unique_name(:sweeper)
    router = unique_name(:router)

    start_supervised!(
      {PassivationSweeper, name: sweeper, interval_ms: 60_000, idle_threshold_ms: 25}
    )

    start_supervised!({SignalRouter, name: router, interval_ms: 60_000})

    assert {:ok, run} = Workflows.start_run(scope, version, %{"kind" => "initial"})

    assert eventually(fn ->
             case {pending_timers(run.id), Workflows.get_run(scope, run.id)} do
               {[_ | _], {:ok, %WorkflowRun{status: :sleeping} = workflow_run}} ->
                 {:ok, workflow_run}

               _ ->
                 :retry
             end
           end)

    worker_pid =
      eventually(fn ->
        case Worker.lookup(run.id) do
          nil -> :retry
          pid -> {:ok, pid}
        end
      end)

    ref = Process.monitor(worker_pid)

    run_ids =
      eventually(fn ->
        case PassivationSweeper.sweep(server: sweeper) do
          {:ok, run_ids} ->
            if run.id in run_ids, do: {:ok, run_ids}, else: :retry

          _ ->
            :retry
        end
      end)

    assert run.id in run_ids
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, :normal}, 2_000
    assert {:ok, %{status: :passivated}} = Workflows.get_run(scope, run.id)

    assert {:ok, %SignalInbox{id: signal_row_id}} =
             SignalRouter.accept_signal(run.id, "sig-passive", "poke", %{"kind" => "signal"},
               server: router
             )

    delivered_signal =
      eventually(fn ->
        case Workflows.get_signal(signal_row_id) do
          {:ok, %SignalInbox{status: :delivered} = signal} -> {:ok, signal}
          _ -> :retry
        end
      end)

    assert delivered_signal.status == :delivered

    assert eventually(fn ->
             case Worker.lookup(run.id) do
               nil -> :retry
               pid when is_pid(pid) -> {:ok, pid}
             end
           end)

    assert eventually(fn ->
             case Workflows.get_run(scope, run.id) do
               {:ok, %WorkflowRun{status: status} = workflow_run}
               when status in [:running, :sleeping] ->
                 {:ok, workflow_run}

               _ ->
                 :retry
             end
           end)

    assert {:ok, _cancelled_run} = Workflows.cancel_run(scope, run.id)
  end

  test "pending signal claims are disjoint and recover stale deliveries", %{scope: scope} do
    run = insert_run(scope, :running)

    signal_ids =
      for index <- 1..4 do
        {:ok, signal} =
          Workflows.create_signal_inbox(run.id, "claim-#{index}", "poke", %{"index" => index})

        signal.id
      end

    task_a =
      Task.async(fn ->
        Workflows.claim_pending_signals(limit: 2, claimed_by: "router-a")
      end)

    task_b =
      Task.async(fn ->
        Workflows.claim_pending_signals(limit: 2, claimed_by: "router-b")
      end)

    assert {:ok, claimed_a} = Task.await(task_a, 2_000)
    assert {:ok, claimed_b} = Task.await(task_b, 2_000)

    claimed_a_ids = Enum.map(claimed_a, & &1.id)
    claimed_b_ids = Enum.map(claimed_b, & &1.id)

    assert length(claimed_a_ids) == 2
    assert length(claimed_b_ids) == 2
    assert MapSet.disjoint?(MapSet.new(claimed_a_ids), MapSet.new(claimed_b_ids))
    assert MapSet.new(claimed_a_ids ++ claimed_b_ids) == MapSet.new(signal_ids)

    assert {:ok, 4} = Workflows.recover_stale_signals(claim_ttl_ms: 0)

    statuses =
      Repo.all(from(signal in SignalInbox, where: signal.id in ^signal_ids))
      |> Enum.map(& &1.status)

    assert Enum.all?(statuses, &(&1 == :pending))
  end

  defp put_workflow_runtime(opts) do
    current = Application.get_env(:fizz, Fizz.Workflows, [])
    Application.put_env(:fizz, Fizz.Workflows, Keyword.merge(current, opts))
  end

  defp insert_run(scope, status) do
    now = DateTime.utc_now()
    %{version: version} = published_version_fixture(scope)

    %WorkflowRun{}
    |> WorkflowRun.changeset(%{
      user_id: scope.user.id,
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

  defp signal_count(run_id, signal_id) do
    SignalInbox
    |> where([signal], signal.run_id == ^run_id and signal.signal_id == ^signal_id)
    |> Repo.aggregate(:count)
  end

  defp signal_count_for_run(run_id) do
    SignalInbox
    |> where([signal], signal.run_id == ^run_id)
    |> Repo.aggregate(:count)
  end

  defp pending_timers(run_id) do
    Repo.all(
      from(timer in DurableTimer,
        where: timer.run_id == ^run_id and timer.status == :pending
      )
    )
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
