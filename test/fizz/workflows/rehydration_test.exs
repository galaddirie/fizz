defmodule Fizz.Workflows.RehydrationTest do
  use Fizz.DataCase, async: false

  import Ecto.Query
  import Fizz.WorkflowsFixtures

  alias Fizz.Workflows
  alias Fizz.Workflows.Compiler
  alias Fizz.Workflows.DurableTimer
  alias Fizz.Workflows.PassivationSweeper
  alias Fizz.Workflows.Runner.Worker
  alias Fizz.Workflows.Store.SqliteStore
  alias Fizz.Workflows.TimerPoller
  alias Fizz.Workflows.WorkflowRun
  alias Runic.Workflow, as: RunicWorkflow

  setup do
    scope = project_scope_fixture()

    tmp_dir =
      Path.join(System.tmp_dir!(), "fizz-rehydration-#{System.unique_integer([:positive])}")

    previous_data_dir = Application.get_env(:fizz, :workflow_data_dir)
    previous_workflow_env = Application.get_env(:fizz, Fizz.Workflows, [])

    Application.put_env(:fizz, :workflow_data_dir, tmp_dir)

    on_exit(fn ->
      Application.put_env(:fizz, :workflow_data_dir, previous_data_dir)
      Application.put_env(:fizz, Fizz.Workflows, previous_workflow_env)
      File.rm_rf(tmp_dir)
    end)

    %{scope: scope, tmp_dir: tmp_dir}
  end

  test "sqlite workflow log replay restores splitter aggregator outputs", %{scope: scope} do
    %{snapshot_attrs: snapshot_attrs, ids: ids} = split_math_collect_snapshot_attrs()
    %{version: version} = published_version_fixture(scope, snapshot_attrs)

    assert {:ok, run} = Workflows.start_run(scope, version, %{"items" => [1, 2, 3]})

    completed_run =
      eventually(fn ->
        with {:ok, %WorkflowRun{status: :completed} = workflow_run} <-
               Workflows.get_run(scope, run.id) do
          {:ok, workflow_run}
        else
          _ -> :retry
        end
      end)

    assert completed_run.output == %{"value" => [[11.0, 12.0, 13.0]]}

    {:ok, store_state} = store_state_for_run(run, scope)
    assert {:ok, event_log} = SqliteStore.load(run.id, store_state)
    assert {:ok, compiled_workflow, _compiled_hash} = Compiler.compile(version)

    restored_workflow = RunicWorkflow.from_events(event_log, compiled_workflow)

    assert RunicWorkflow.raw_productions(restored_workflow, ids.aggregator) == [
             [11.0, 12.0, 13.0]
           ]

    assert RunicWorkflow.raw_productions(restored_workflow, ids.output) == [[11.0, 12.0, 13.0]]
    assert Map.get(restored_workflow, :fizz_metadata).result_step_ids == [ids.output]

    assert_worker_shutdown(run.id)
  end

  test "passivated splitter aggregator workflow resumes from sqlite checkpoint and completes", %{
    scope: scope
  } do
    put_workflow_runtime(idle_timeout_ms: 25)

    %{snapshot_attrs: snapshot_attrs, ids: ids} = split_math_wait_collect_snapshot_attrs(250)
    %{version: version} = published_version_fixture(scope, snapshot_attrs)

    poller = unique_name(:poller)
    sweeper = unique_name(:sweeper)

    start_supervised!({TimerPoller, name: poller, interval_ms: 60_000, claim_ttl_ms: 100})

    start_supervised!(
      {PassivationSweeper, name: sweeper, interval_ms: 60_000, idle_threshold_ms: 25}
    )

    assert {:ok, run} = Workflows.start_run(scope, version, %{"items" => [1, 2, 3]})

    timers =
      eventually(fn ->
        pending_timers = pending_timers_for_run(run.id)

        case {pending_timers, Workflows.get_run(scope, run.id)} do
          {[%DurableTimer{}, %DurableTimer{}, %DurableTimer{}] = timers,
           {:ok, %WorkflowRun{status: :sleeping}}} ->
            {:ok, timers}

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

    passivated_run_ids =
      eventually(fn ->
        case PassivationSweeper.sweep(server: sweeper) do
          {:ok, run_ids} ->
            if run.id in run_ids, do: {:ok, run_ids}, else: :retry

          _ ->
            :retry
        end
      end)

    assert run.id in passivated_run_ids
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, :normal}, 2_000
    assert {:ok, %{status: :passivated}} = Workflows.get_run(scope, run.id)

    {:ok, store_state} = store_state_for_run(run, scope)
    assert {:ok, _event_log} = SqliteStore.load(run.id, store_state)

    timer_ids = Enum.map(timers, & &1.id) |> MapSet.new()

    fired_ids =
      eventually(fn ->
        _ = TimerPoller.poll(server: poller)

        fired_ids =
          DurableTimer
          |> where([timer], timer.id in ^MapSet.to_list(timer_ids) and timer.status == :fired)
          |> select([timer], timer.id)
          |> Repo.all()

        if MapSet.subset?(timer_ids, MapSet.new(fired_ids)), do: {:ok, fired_ids}, else: :retry
      end)

    assert MapSet.subset?(timer_ids, MapSet.new(fired_ids))

    completed_run =
      eventually(fn ->
        with {:ok, %WorkflowRun{status: :completed} = workflow_run} <-
               Workflows.get_run(scope, run.id) do
          {:ok, workflow_run}
        else
          _ -> :retry
        end
      end)

    assert completed_run.output == %{"value" => [[11.0, 12.0, 13.0]]}

    assert {:ok, step_executions} = Workflows.list_run_step_executions(scope, run.id)

    math_executions =
      step_executions
      |> Enum.filter(&(&1.step_id == ids.math))
      |> Enum.sort_by(& &1.item_index)

    assert Enum.map(math_executions, & &1.item_index) == [0, 1, 2]
    assert Enum.map(math_executions, & &1.output_data) == [11.0, 12.0, 13.0]

    aggregator_executions =
      step_executions
      |> Enum.filter(&(&1.step_id == ids.aggregator))

    assert [aggregator_execution] = aggregator_executions
    assert aggregator_execution.output_data == [11.0, 12.0, 13.0]

    assert_worker_shutdown(run.id)
  end

  defp split_math_collect_snapshot_attrs do
    trigger = step(%{type_id: "manual_input", name: "Manual Trigger"})

    splitter =
      step(%{
        type_id: "splitter",
        name: "Split Items",
        config: %{"field" => "{{ json.items }}"}
      })

    math =
      step(%{
        type_id: "math",
        name: "Add Ten",
        config: %{"operation" => "add", "value" => "{{ input }}", "operand" => 10}
      })

    aggregator =
      step(%{
        type_id: "aggregator",
        name: "Collect",
        config: %{"operation" => "collect"}
      })

    output = step(%{type_id: "data_output", name: "Output"})

    snapshot_attrs =
      snapshot_attrs(%{
        steps: [trigger, splitter, math, aggregator, output],
        connections: [
          connection(%{source_step_id: trigger.id, target_step_id: splitter.id}),
          connection(%{source_step_id: splitter.id, target_step_id: math.id}),
          connection(%{source_step_id: math.id, target_step_id: aggregator.id}),
          connection(%{source_step_id: aggregator.id, target_step_id: output.id})
        ]
      })

    %{
      snapshot_attrs: snapshot_attrs,
      ids: %{math: math.id, aggregator: aggregator.id, output: output.id}
    }
  end

  defp split_math_wait_collect_snapshot_attrs(duration_ms) do
    trigger = step(%{type_id: "manual_input", name: "Manual Trigger"})

    splitter =
      step(%{
        type_id: "splitter",
        name: "Split Items",
        config: %{"field" => "{{ json.items }}"}
      })

    math =
      step(%{
        type_id: "math",
        name: "Add Ten",
        config: %{"operation" => "add", "value" => "{{ input }}", "operand" => 10}
      })

    wait_step =
      step(%{
        type_id: "wait",
        name: "Wait",
        config: %{"duration" => duration_ms, "unit" => "milliseconds"}
      })

    aggregator =
      step(%{
        type_id: "aggregator",
        name: "Collect",
        config: %{"operation" => "collect"}
      })

    output = step(%{type_id: "data_output", name: "Output"})

    snapshot_attrs =
      snapshot_attrs(%{
        steps: [trigger, splitter, math, wait_step, aggregator, output],
        connections: [
          connection(%{source_step_id: trigger.id, target_step_id: splitter.id}),
          connection(%{source_step_id: splitter.id, target_step_id: math.id}),
          connection(%{source_step_id: math.id, target_step_id: wait_step.id}),
          connection(%{source_step_id: wait_step.id, target_step_id: aggregator.id}),
          connection(%{source_step_id: aggregator.id, target_step_id: output.id})
        ]
      })

    %{
      snapshot_attrs: snapshot_attrs,
      ids: %{math: math.id, aggregator: aggregator.id, output: output.id}
    }
  end

  defp store_state_for_run(run, scope) do
    SqliteStore.init(run.id,
      org_id: scope.project.workos_organization_id,
      project_id: scope.project.id,
      fence_token: 0,
      repo: Repo
    )
  end

  defp pending_timers_for_run(run_id) do
    DurableTimer
    |> where([timer], timer.run_id == ^run_id and timer.status == :pending)
    |> order_by([timer], asc: timer.inserted_at)
    |> Repo.all()
  end

  defp put_workflow_runtime(opts) do
    current = Application.get_env(:fizz, Fizz.Workflows, [])
    Application.put_env(:fizz, Fizz.Workflows, Keyword.merge(current, opts))
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

  defp assert_worker_shutdown(run_id) do
    case Worker.lookup(run_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end
  end

  defp unique_name(name) do
    Module.concat([__MODULE__, "#{name}_#{System.unique_integer([:positive])}"])
  end
end
