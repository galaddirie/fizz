defmodule Fizz.Workflows.Runner.Worker do
  @moduledoc """
  Internal GenServer that owns the live execution of a single workflow run.

  The worker wraps Runic's three-phase execution model for Fizz:

  1. prepare pending runnables from the current workflow state
  2. dispatch runnable execution through `Task.Supervisor.async_nolink/4`
  3. apply completed runnables back through a single-writer boundary

  In addition to the in-memory Runic workflow, the worker coordinates
  checkpointing, run activity timestamps, terminal status updates, and lease
  release on shutdown.
  """

  use GenServer

  alias Fizz.Workflows
  alias Fizz.Workflows.{DurableTimer, SignalInbox}
  alias Fizz.Workflows.LeaseManager
  alias Fizz.Workflows.StepExecutionTrace
  alias Fizz.Workflows.Store.{CheckpointStrategy, SqliteStore}
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    FanOut,
    Invokable,
    Runnable,
    RunnableCompleted,
    RunnableDispatched,
    RunnableFailed
  }

  alias Runic.Workflow.Events.{ActivationConsumed, FactProduced, MapReduceTracked}
  alias Runic.Workflow.SchedulerPolicy

  require Logger

  @default_idle_timeout_ms 60_000
  @output_summary_limit 1_024

  defstruct [
    :run_id,
    :workflow,
    :store,
    :fence_token,
    :checkpoint_strategy,
    :max_concurrency,
    :task_supervisor,
    :registry,
    :idle_timeout_ms,
    :idle_timer_ref,
    :status,
    cycle_count: 0,
    active_tasks: %{},
    local_timers: %{}
  ]

  def child_spec(opts) do
    run_id = Keyword.fetch!(opts, :run_id)

    %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @doc """
  Starts a worker registered under the configured workflow runner registry.
  """
  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    registry = Keyword.get(opts, :registry, Fizz.Workflows.Runner.Registry)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(registry, run_id))
  end

  @doc """
  Starts execution for an idle worker using the given external input.
  """
  def run(pid, input) when is_pid(pid) do
    GenServer.cast(pid, {:run, input})
    :ok
  end

  def run(run_id, input) when is_binary(run_id) do
    case lookup(run_id) do
      nil ->
        {:error, :not_found}

      pid ->
        run(pid, input)
    end
  end

  @doc """
  Delivers an external workflow event to a running worker and waits for it to be
  incorporated into the in-memory workflow state.
  """
  def deliver_event(pid, event) when is_pid(pid) do
    GenServer.call(pid, {:deliver_event, event}, :infinity)
  end

  def deliver_event(run_id, event) when is_binary(run_id) do
    case lookup(run_id) do
      nil ->
        {:error, :not_found}

      pid ->
        deliver_event(pid, event)
    end
  end

  @doc """
  Stops a worker and optionally persists a final checkpoint before shutdown.
  """
  def stop(target, opts \\ [])

  def stop(pid, opts) when is_pid(pid) do
    GenServer.call(pid, {:stop, opts}, :infinity)
  end

  def stop(run_id, opts) when is_binary(run_id) and is_list(opts) do
    case lookup(run_id, opts) do
      nil ->
        {:error, :not_found}

      pid ->
        stop(pid, opts)
    end
  end

  @doc """
  Looks up a worker process by run id.
  """
  def lookup(run_id, opts \\ []) when is_binary(run_id) do
    registry = Keyword.get(opts, :registry, Fizz.Workflows.Runner.Registry)

    case Registry.lookup(registry, run_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  Executes a prepared Runic runnable in isolation.
  """
  def execute_runnable(%Runnable{} = runnable) do
    Invokable.execute(runnable.node, runnable)
  end

  @impl true
  def init(opts) do
    workflow =
      case Keyword.get(opts, :run_context) do
        context when is_map(context) ->
          Workflow.put_run_context(Keyword.fetch!(opts, :workflow), context)

        _ ->
          Keyword.fetch!(opts, :workflow)
      end

    state = %__MODULE__{
      run_id: Keyword.fetch!(opts, :run_id),
      workflow: workflow,
      store: Keyword.fetch!(opts, :store),
      fence_token: Keyword.fetch!(opts, :fence_token),
      checkpoint_strategy: Keyword.get(opts, :checkpoint_strategy, :every_cycle),
      max_concurrency: normalize_max_concurrency(Keyword.get(opts, :max_concurrency)),
      task_supervisor: Keyword.get(opts, :task_supervisor, Fizz.Workflows.Runner.TaskSupervisor),
      registry: Keyword.get(opts, :registry, Fizz.Workflows.Runner.Registry),
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, @default_idle_timeout_ms),
      status: :idle
    }

    {:ok, schedule_idle_timeout(state)}
  end

  @impl true
  def handle_cast({:run, input}, state) do
    case process_event(state, {:input, input}) do
      {:continue, next_state} -> {:noreply, next_state}
      {:stop, next_state} -> {:stop, :normal, next_state}
      {:error, reason, next_state} -> {:stop, :normal, fail_and_stop(next_state, reason)}
    end
  end

  @impl true
  def handle_call({:stop, opts}, _from, state) do
    state =
      state
      |> cancel_idle_timeout()
      |> cancel_local_timers()
      |> maybe_checkpoint_before_stop(opts)
      |> shutdown_active_tasks()

    {:stop, :normal, :ok, state}
  end

  def handle_call({:deliver_event, event}, _from, state) do
    case process_event(state, event) do
      {:continue, next_state} ->
        {:reply, :ok, next_state}

      {:stop, next_state} ->
        {:stop, :normal, :ok, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, schedule_idle_timeout(next_state)}
    end
  end

  @impl true
  def handle_info({ref, %Runnable{} = executed}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.active_tasks, ref) do
      {nil, _active_tasks} ->
        {:noreply, state}

      {task_state, active_tasks} ->
        case handle_completed_task(%{state | active_tasks: active_tasks}, executed, task_state) do
          {:continue, next_state} -> {:noreply, next_state}
          {:stop, next_state} -> {:stop, :normal, next_state}
          {:error, reason, next_state} -> {:stop, :normal, fail_and_stop(next_state, reason)}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    case Map.pop(state.active_tasks, ref) do
      {nil, _active_tasks} ->
        {:noreply, state}

      {task_state, active_tasks} ->
        failed_runnable = Runnable.fail(task_state.runnable, {:task_crashed, reason})

        state =
          state
          |> Map.put(:active_tasks, active_tasks)
          |> append_runnable_result_event(failed_runnable, task_state)
          |> apply_runnable(failed_runnable)
          |> bump_cycle_count()

        _ = Workflows.touch_run_activity(state.run_id)

        {:stop, :normal, fail_and_stop(state, {:task_crashed, reason})}
    end
  end

  def handle_info(:timeout, state) do
    state =
      case {state.status, map_size(state.active_tasks)} do
        {status, 0} when status in [:running, :sleeping] -> do_checkpoint(state)
        _ -> state
      end

    {:noreply, schedule_idle_timeout(state)}
  end

  def handle_info({:local_timer_due, timer_id}, state) do
    state = drop_local_timer(state, timer_id)

    case Workflows.claim_timer(timer_id, claimed_by: local_timer_owner(state)) do
      {:ok, %DurableTimer{} = timer} ->
        case process_event(state, {:timer_fired, timer}) do
          {:continue, next_state} ->
            :ok = Workflows.mark_timer_fired(timer.id)
            {:noreply, next_state}

          {:stop, next_state} ->
            :ok = Workflows.mark_timer_fired(timer.id)
            {:stop, :normal, next_state}

          {:error, _reason, next_state} ->
            {:noreply, schedule_idle_timeout(next_state)}
        end

      {:error, :not_found} ->
        {:noreply, state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(:normal, state) do
    # Normal shutdown (via Worker.stop/2 or workflow completion) — just clean up.
    # The caller (e.g. cancel_run) is responsible for setting the final status.
    state
    |> cancel_idle_timeout()
    |> cancel_local_timers()
    |> shutdown_active_tasks()

    :ok
  end

  def terminate(_reason, state) do
    state =
      state
      |> cancel_idle_timeout()
      |> cancel_local_timers()
      |> broadcast_active_tasks_cancelled()
      |> shutdown_active_tasks()

    # Safety net: if run is still non-terminal in DB, mark it as failed.
    # fail_run/2 internally fetches the run and handles already-failed runs,
    # so we just call it and handle errors gracefully.
    case Workflows.fail_run(state.run_id, :worker_terminated) do
      {:ok, _run} ->
        _ =
          broadcast(
            state.run_id,
            {:run_status_changed, status_payload(state.run_id, :failed)}
          )

      {:error, _reason} ->
        # Run was already terminal or not found — nothing to do
        :ok
    end

    :ok
  end

  defp dispatch_cycle(state) do
    {workflow, runnables} = Workflow.prepare_for_dispatch(state.workflow)

    state =
      state
      |> cancel_idle_timeout()
      |> Map.put(:workflow, workflow)
      |> dispatch_runnables(runnables)

    cond do
      map_size(state.active_tasks) > 0 ->
        {:continue, state}

      Workflow.is_runnable?(state.workflow) ->
        {:continue, schedule_idle_timeout(%{state | status: :running})}

      Workflows.run_has_pending_timers?(state.run_id) ->
        _ = Workflows.sleep_run(state.run_id)
        {:continue, schedule_idle_timeout(%{state | status: :sleeping})}

      state.status == :running ->
        {:stop, complete_and_stop(state)}

      true ->
        {:continue, schedule_idle_timeout(state)}
    end
  end

  defp dispatch_runnables(state, runnables) do
    available_slots = max(state.max_concurrency - map_size(state.active_tasks), 0)

    active_runnable_ids =
      Map.values(state.active_tasks) |> Enum.map(& &1.runnable.id) |> MapSet.new()

    runnables
    |> Enum.reject(&MapSet.member?(active_runnable_ids, &1.id))
    |> Enum.take(available_slots)
    |> Enum.reduce(state, fn runnable, acc -> dispatch_runnable(acc, runnable) end)
  end

  defp dispatch_runnable(state, %Runnable{} = runnable) do
    dispatched_at_us = System.monotonic_time(:microsecond)

    task =
      Task.Supervisor.async_nolink(
        state.task_supervisor,
        __MODULE__,
        :execute_runnable,
        [runnable]
      )

    task_state = %{
      dispatched_at_us: dispatched_at_us,
      pid: task.pid,
      runnable: runnable
    }

    event = %RunnableDispatched{
      runnable_id: runnable.id,
      node_name: Map.get(runnable.node, :name),
      node_hash: Map.get(runnable.node, :hash),
      input_fact: runnable.input_fact,
      dispatched_at: System.convert_time_unit(dispatched_at_us, :microsecond, :millisecond),
      policy: SchedulerPolicy.default_policy(),
      attempt: 0
    }

    state = %{
      state
      | workflow: Workflow.append_runnable_events(state.workflow, [event]),
        active_tasks: Map.put(state.active_tasks, task.ref, task_state)
    }

    maybe_broadcast_step_started(state, runnable)
    state
  end

  defp process_event(state, {:input, input}) do
    state =
      state
      |> cancel_idle_timeout()
      |> ensure_running_state()
      |> plan_workflow_input(input)

    _ = Workflows.touch_run_activity(state.run_id)

    dispatch_cycle(state)
  end

  defp process_event(state, {:signal, %SignalInbox{} = signal}) do
    process_event(state, {:input, signal_to_input(signal)})
  end

  defp process_event(state, {:timer_fired, %DurableTimer{} = timer}) do
    with {:ok, runnable} <- delayed_timer_runnable(state.workflow, timer) do
      state =
        state
        |> cancel_idle_timeout()
        |> ensure_running_state()
        |> drop_local_timer(timer.id)
        |> append_delayed_runnable_result_event(runnable)
        |> apply_runnable(runnable)
        |> bump_cycle_count()

      _ = Workflows.touch_run_activity(state.run_id)

      state = maybe_checkpoint(state, %{cycle_count: state.cycle_count, status: :running})
      :ok = Workflows.mark_timer_fired(timer.id)

      dispatch_cycle(state)
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp process_event(state, _event), do: {:error, :unsupported_event, state}

  defp handle_completed_task(state, %Runnable{status: :failed} = executed, task_state) do
    state =
      state
      |> append_runnable_result_event(executed, task_state)
      |> apply_runnable(executed)
      |> bump_cycle_count()

    _ = Workflows.touch_run_activity(state.run_id)

    {:stop, fail_and_stop(state, executed.error)}
  end

  defp handle_completed_task(state, %Runnable{status: :completed} = executed, task_state) do
    case timer_intent(executed) do
      {:ok, timer_spec} ->
        handle_timer_intent(state, executed, timer_spec)

      :none ->
        state =
          state
          |> append_runnable_result_event(executed, task_state)
          |> apply_runnable(executed)
          |> bump_cycle_count()

        _ = Workflows.touch_run_activity(state.run_id)

        state = maybe_checkpoint(state, %{cycle_count: state.cycle_count, status: :running})

        dispatch_cycle(state)
    end
  end

  defp handle_completed_task(state, %Runnable{} = executed, task_state) do
    state =
      state
      |> append_runnable_result_event(executed, task_state)
      |> apply_runnable(executed)
      |> bump_cycle_count()

    _ = Workflows.touch_run_activity(state.run_id)

    state = maybe_checkpoint(state, %{cycle_count: state.cycle_count, status: :running})

    dispatch_cycle(state)
  end

  defp handle_timer_intent(state, executed, timer_spec) do
    payload = delayed_timer_payload(executed, timer_spec.output)

    with {:ok, timer} <-
           Workflows.create_timer(
             state.run_id,
             timer_spec.step_id,
             timer_spec.fire_at,
             timer_name: timer_spec.timer_name,
             payload: payload
           ) do
      state =
        state
        |> apply_runnable(timer_placeholder_runnable(executed))
        |> bump_cycle_count()
        |> maybe_schedule_local_timer(timer)
        |> mark_sleeping_state()

      _ = Workflows.touch_run_activity(state.run_id)

      state = maybe_checkpoint(state, %{cycle_count: state.cycle_count, status: :sleeping})

      dispatch_cycle(state)
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp timer_intent(%Runnable{result: %Fact{value: {:sleep, duration_ms, output}}, node: node})
       when is_integer(duration_ms) and duration_ms >= 0 do
    fire_at = DateTime.add(DateTime.utc_now(), duration_ms, :millisecond)
    step_id = to_string(Map.get(node, :name))

    {:ok, %{fire_at: fire_at, output: output, step_id: step_id, timer_name: step_id}}
  end

  defp timer_intent(%Runnable{
         result: %Fact{value: {:schedule_at, %DateTime{} = fire_at, output}},
         node: node
       }) do
    step_id = to_string(Map.get(node, :name))

    {:ok,
     %{
       fire_at: DateTime.from_unix!(DateTime.to_unix(fire_at, :microsecond), :microsecond),
       output: output,
       step_id: step_id,
       timer_name: step_id
     }}
  end

  defp timer_intent(_runnable), do: :none

  defp delayed_timer_payload(%Runnable{} = runnable, output) do
    %{
      "format" => "erlang_term_v1",
      "data" =>
        runnable
        |> delayed_timer_data(output)
        |> :erlang.term_to_binary([:compressed])
        |> Base.encode64()
    }
  end

  defp delayed_timer_data(%Runnable{} = runnable, output) do
    %{
      node_hash: Map.get(runnable.node, :hash),
      input_fact_hash: runnable.input_fact.hash,
      ancestry_depth: Map.get(runnable.context, :ancestry_depth, 0),
      tracks: timer_tracks(runnable.context),
      output: output
    }
  end

  defp timer_tracks(%{fan_out_context: %{tracks: tracks}}) when is_list(tracks), do: tracks
  defp timer_tracks(_context), do: []

  defp delayed_timer_runnable(workflow, %DurableTimer{payload: payload}) do
    with %{"format" => "erlang_term_v1", "data" => encoded} <- payload || %{},
         {:ok, binary} <- Base.decode64(encoded),
         %{node_hash: node_hash, input_fact_hash: input_fact_hash} = data <-
           :erlang.binary_to_term(binary),
         %{} = node <- Map.get(workflow.graph.vertices, node_hash),
         %Fact{} = input_fact <- Map.get(workflow.graph.vertices, input_fact_hash) do
      result_fact = Fact.new(value: data.output, ancestry: {node.hash, input_fact.hash})

      runnable = %Runnable{
        id: Runnable.runnable_id(node, input_fact),
        status: :completed,
        node: node,
        input_fact: input_fact,
        result: result_fact,
        events:
          delayed_timer_events(
            node,
            result_fact,
            Map.get(data, :ancestry_depth, 0),
            Map.get(data, :tracks, [])
          )
      }

      {:ok, runnable}
    else
      _ -> {:error, :invalid_timer_payload}
    end
  end

  defp delayed_timer_events(node, result_fact, ancestry_depth, tracks) do
    produced = %FactProduced{
      hash: result_fact.hash,
      value: result_fact.value,
      ancestry: result_fact.ancestry,
      producer_label: :produced,
      weight: ancestry_depth + 1
    }

    tracked =
      Enum.map(tracks, fn %{
                            source_fact_hash: source_fact_hash,
                            fan_out_hash: fan_out_hash,
                            fan_out_fact_hash: fan_out_fact_hash
                          } ->
        %MapReduceTracked{
          source_fact_hash: source_fact_hash,
          fan_out_hash: fan_out_hash,
          fan_out_fact_hash: fan_out_fact_hash,
          step_hash: node.hash,
          result_fact_hash: result_fact.hash
        }
      end)

    [produced | tracked]
  end

  defp timer_placeholder_runnable(%Runnable{} = runnable) do
    %Runnable{
      runnable
      | result: :waiting,
        events: [activation_consumed_event(runnable)]
    }
  end

  defp activation_consumed_event(%Runnable{input_fact: input_fact, node: node}) do
    %ActivationConsumed{
      fact_hash: input_fact.hash,
      node_hash: Map.get(node, :hash),
      from_label: :runnable
    }
  end

  defp plan_workflow_input(state, input) do
    state
    |> maybe_broadcast_status_change(:running)
    |> then(fn next_state ->
      %{
        next_state
        | workflow: Workflow.plan_eagerly(next_state.workflow, input),
          status: :running
      }
    end)
  end

  defp ensure_running_state(state) do
    _ = Workflows.resume_run(state.run_id)

    state
    |> maybe_broadcast_status_change(:running)
    |> Map.put(:status, :running)
  end

  defp mark_sleeping_state(state) do
    _ = Workflows.sleep_run(state.run_id)

    state
    |> maybe_broadcast_status_change(:sleeping)
    |> Map.put(:status, :sleeping)
  end

  defp signal_to_input(%SignalInbox{} = signal) do
    %{
      "type" => "signal",
      "signal_id" => signal.signal_id,
      "signal_name" => signal.signal_name,
      "payload" => signal.payload
    }
  end

  defp append_runnable_result_event(state, %Runnable{status: :completed} = runnable, task_state) do
    duration_us = duration_us(task_state)

    event = %RunnableCompleted{
      runnable_id: runnable.id,
      node_hash: Map.get(runnable.node, :hash),
      result_fact: runnable.result,
      completed_at: System.monotonic_time(:millisecond),
      attempt: 0,
      duration_ms: duration_ms(duration_us),
      duration_us: duration_us
    }

    maybe_broadcast_step_completed(state, runnable, duration_us)

    %{state | workflow: Workflow.append_runnable_events(state.workflow, [event])}
  end

  defp append_runnable_result_event(
         state,
         %Runnable{status: :failed, error: error} = runnable,
         task_state
       ) do
    duration_us = duration_us(task_state)

    event = %RunnableFailed{
      runnable_id: runnable.id,
      node_hash: Map.get(runnable.node, :hash),
      error: error,
      failed_at: System.monotonic_time(:millisecond),
      duration_us: duration_us,
      attempts: 1,
      failure_action: :halt
    }

    maybe_broadcast_step_failed(state, runnable, duration_us)

    %{state | workflow: Workflow.append_runnable_events(state.workflow, [event])}
  end

  defp append_runnable_result_event(state, _runnable, _task_state), do: state

  defp append_delayed_runnable_result_event(state, %Runnable{} = runnable) do
    event = %RunnableCompleted{
      runnable_id: runnable.id,
      node_hash: Map.get(runnable.node, :hash),
      result_fact: runnable.result,
      completed_at: System.monotonic_time(:millisecond),
      attempt: 0,
      duration_ms: 0,
      duration_us: 0
    }

    maybe_broadcast_step_completed(state, runnable, 0)

    %{state | workflow: Workflow.append_runnable_events(state.workflow, [event])}
  end

  defp apply_runnable(state, %Runnable{} = runnable) do
    %{state | workflow: Workflow.apply_runnable(state.workflow, runnable)}
  end

  defp bump_cycle_count(state), do: %{state | cycle_count: state.cycle_count + 1}

  defp maybe_checkpoint(state, event) do
    if CheckpointStrategy.should_checkpoint?(state.checkpoint_strategy, event) do
      do_checkpoint(state)
    else
      state
    end
  end

  defp do_checkpoint(state) do
    :ok = SqliteStore.save(state.run_id, Workflow.event_log(state.workflow), state.store)
    state
  end

  defp maybe_checkpoint_before_stop(state, opts) do
    if Keyword.get(opts, :persist, true) do
      do_checkpoint(state)
    else
      state
    end
  end

  defp complete_and_stop(state) do
    state = do_checkpoint(state)
    _ = Workflows.complete_run(state.run_id, workflow_output(state.workflow))

    _ =
      broadcast(state.run_id, {:run_status_changed, status_payload(state.run_id, :completed)})

    _ = release_lease(state.run_id)
    state
  end

  defp fail_and_stop(state, reason) do
    # 1. Broadcast :step_cancelled for every active sibling task
    state = broadcast_active_tasks_cancelled(state)

    # 2. Shutdown active tasks
    state = shutdown_active_tasks(state)

    # 3. Checkpoint — wrapped in try/rescue so failure doesn't prevent DB update
    state =
      try do
        do_checkpoint(state)
      rescue
        e ->
          Logger.error("Checkpoint failed during fail_and_stop: #{Exception.message(e)}")
          state
      end

    # 4. Mark run as failed in DB — log on error
    case Workflows.fail_run(state.run_id, reason) do
      {:ok, _run} -> :ok
      {:error, fail_reason} -> Logger.error("fail_run failed: #{inspect(fail_reason)}")
    end

    # 5. Broadcast terminal status
    _ = broadcast(state.run_id, {:run_status_changed, status_payload(state.run_id, :failed)})

    # 6. Release lease
    _ = release_lease(state.run_id)

    state
  end

  defp release_lease(run_id) do
    case LeaseManager.release(run_id) do
      :ok -> :ok
      {:error, :not_owner} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp shutdown_active_tasks(
         %__MODULE__{active_tasks: active_tasks, task_supervisor: task_supervisor} = state
       ) do
    Enum.each(active_tasks, fn {_ref, task_state} ->
      _ = Task.Supervisor.terminate_child(task_supervisor, task_state.pid)
    end)

    %{state | active_tasks: %{}}
  end

  defp maybe_schedule_local_timer(%__MODULE__{} = state, %DurableTimer{} = timer) do
    if hot_timer?(state, timer.fire_at) do
      delay_ms = max(DateTime.diff(timer.fire_at, DateTime.utc_now(), :millisecond), 0)
      ref = Process.send_after(self(), {:local_timer_due, timer.id}, delay_ms)

      state
      |> drop_local_timer(timer.id)
      |> put_local_timer(timer.id, ref)
    else
      state
    end
  end

  defp hot_timer?(%__MODULE__{idle_timeout_ms: timeout_ms}, %DateTime{} = fire_at)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    DateTime.diff(fire_at, DateTime.utc_now(), :millisecond) <= timeout_ms
  end

  defp hot_timer?(_state, _fire_at), do: false

  defp put_local_timer(%__MODULE__{local_timers: local_timers} = state, timer_id, ref) do
    %{state | local_timers: Map.put(local_timers, timer_id, ref)}
  end

  defp drop_local_timer(%__MODULE__{local_timers: local_timers} = state, timer_id) do
    case Map.pop(local_timers, timer_id) do
      {nil, timers} ->
        %{state | local_timers: timers}

      {ref, timers} ->
        Process.cancel_timer(ref)
        %{state | local_timers: timers}
    end
  end

  defp cancel_local_timers(%__MODULE__{local_timers: local_timers} = state) do
    Enum.each(local_timers, fn {_timer_id, ref} -> Process.cancel_timer(ref) end)
    %{state | local_timers: %{}}
  end

  defp local_timer_owner(state) do
    "#{Atom.to_string(node())}:worker:#{state.run_id}"
  end

  defp schedule_idle_timeout(%__MODULE__{idle_timeout_ms: timeout_ms} = state)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    %{state | idle_timer_ref: Process.send_after(self(), :timeout, timeout_ms)}
  end

  defp schedule_idle_timeout(state), do: state

  defp cancel_idle_timeout(%__MODULE__{idle_timer_ref: nil} = state), do: state

  defp cancel_idle_timeout(%__MODULE__{idle_timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    %{state | idle_timer_ref: nil}
  end

  defp normalize_max_concurrency(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_concurrency(_value), do: max(System.schedulers_online(), 1)

  defp maybe_broadcast_step_started(state, %Runnable{} = runnable) do
    with {:ok, step_id} <- runnable_step_id(runnable) do
      payload =
        %{
          run_id: state.run_id,
          runnable_id: runnable.id,
          step_id: step_id,
          attempt: 0,
          input: runnable.input_fact.value,
          input_fact_hash: runnable.input_fact.hash,
          started_at: DateTime.utc_now()
        }
        |> put_iteration_metadata(runnable.input_fact)

      _ =
        broadcast(
          state.run_id,
          {:step_started, payload}
        )

      :ok
    end
  end

  defp maybe_broadcast_step_completed(state, %Runnable{} = runnable, duration_us) do
    case splitter_iteration_payloads(state.run_id, runnable, duration_us) do
      {:ok, payloads} ->
        Enum.each(payloads, fn payload ->
          _ = broadcast(state.run_id, {:step_completed, payload})
        end)

        :ok

      :error ->
        with {:ok, step_id} <- runnable_step_id(runnable) do
          output = runnable_output(runnable)

          payload =
            %{
              run_id: state.run_id,
              runnable_id: runnable.id,
              step_id: step_id,
              attempt: 0,
              input: runnable.input_fact.value,
              input_fact_hash: runnable.input_fact.hash,
              output: output,
              output_item_count: output_item_count(output),
              output_fact_hash: output_fact_hash(runnable),
              output_summary: truncate_output(output),
              duration_us: duration_us,
              completed_at: DateTime.utc_now()
            }
            |> put_iteration_metadata(runnable.input_fact)

          _ = broadcast(state.run_id, {:step_completed, payload})

          :ok
        end
    end
  end

  defp maybe_broadcast_step_failed(state, %Runnable{} = runnable, duration_us) do
    with {:ok, step_id} <- runnable_step_id(runnable) do
      payload =
        %{
          run_id: state.run_id,
          runnable_id: runnable.id,
          step_id: step_id,
          attempt: 0,
          input: runnable.input_fact.value,
          input_fact_hash: runnable.input_fact.hash,
          error: encode_error(runnable.error),
          duration_us: duration_us,
          failed_at: DateTime.utc_now()
        }
        |> put_iteration_metadata(runnable.input_fact)

      _ =
        broadcast(
          state.run_id,
          {:step_failed, payload}
        )

      :ok
    end
  end

  defp broadcast_active_tasks_cancelled(%__MODULE__{active_tasks: active_tasks} = state) do
    now = DateTime.utc_now()

    Enum.each(active_tasks, fn {_ref, task_state} ->
      maybe_broadcast_step_cancelled(state, task_state.runnable, now)
    end)

    state
  end

  defp maybe_broadcast_step_cancelled(state, %Runnable{} = runnable, cancelled_at) do
    with {:ok, step_id} <- runnable_step_id(runnable) do
      payload = %{
        run_id: state.run_id,
        runnable_id: runnable.id,
        step_id: step_id,
        cancelled_at: cancelled_at
      }

      _ = broadcast(state.run_id, {:step_cancelled, payload})

      :ok
    end
  end

  defp maybe_broadcast_status_change(%__MODULE__{status: status} = state, new_status)
       when status == new_status,
       do: state

  defp maybe_broadcast_status_change(%__MODULE__{} = state, new_status) do
    _ = broadcast(state.run_id, {:run_status_changed, status_payload(state.run_id, new_status)})
    state
  end

  defp status_payload(run_id, status) do
    %{
      run_id: run_id,
      status: status,
      timestamp: DateTime.utc_now()
    }
  end

  defp duration_ms(duration_us) when is_integer(duration_us) and duration_us >= 0,
    do: div(duration_us, 1_000)

  defp duration_ms(_duration_us), do: 0

  defp duration_us(%{dispatched_at_us: dispatched_at_us}) when is_integer(dispatched_at_us) do
    max(System.monotonic_time(:microsecond) - dispatched_at_us, 0)
  end

  defp duration_us(_task_state), do: 0

  defp runnable_step_id(%Runnable{node: %{name: name}}), do: logical_step_id(name)
  defp runnable_step_id(_runnable), do: :error

  defp logical_step_id(name), do: StepExecutionTrace.logical_step_id(name)

  defp runnable_output(%Runnable{result: %Fact{value: value}}), do: value
  defp runnable_output(%Runnable{result: value}), do: value

  defp output_item_count(nil), do: nil
  defp output_item_count(output) when is_list(output), do: length(output)
  defp output_item_count(_output), do: 1

  defp output_fact_hash(%Runnable{result: %Fact{hash: hash}}), do: hash
  defp output_fact_hash(_runnable), do: nil

  defp splitter_iteration_payloads(
         run_id,
         %Runnable{node: %FanOut{name: name}} = runnable,
         duration_us
       ) do
    with {:ok, step_id} <- StepExecutionTrace.splitter_fan_out_step_id(name),
         emitted_facts when emitted_facts != [] <- splitter_emitted_facts(runnable.result) do
      items_total = length(emitted_facts)
      completed_at = DateTime.utc_now()
      per_item_duration = per_item_duration_us(duration_us, items_total)
      started_at = DateTime.add(completed_at, -per_item_duration, :microsecond)

      payloads =
        Enum.map(Enum.with_index(emitted_facts), fn {fact, fallback_index} ->
          item_index = StepExecutionTrace.fact_item_index(fact) || fallback_index

          %{
            run_id: run_id,
            runnable_id: runnable.id,
            execution_key: "#{runnable.id}:#{item_index}",
            step_id: step_id,
            attempt: 0,
            input: runnable.input_fact.value,
            input_fact_hash: runnable.input_fact.hash,
            output: fact.value,
            output_item_count: 1,
            output_fact_hash: fact.hash,
            output_summary: truncate_output(fact.value),
            duration_us: per_item_duration,
            started_at: started_at,
            completed_at: completed_at,
            item_index: item_index,
            items_total: StepExecutionTrace.fact_items_total(fact) || items_total
          }
        end)

      {:ok, payloads}
    else
      _ -> :error
    end
  end

  defp splitter_iteration_payloads(_run_id, _runnable, _duration_us), do: :error

  defp splitter_emitted_facts(result) when is_list(result) do
    Enum.filter(result, &match?(%Fact{}, &1))
  end

  defp splitter_emitted_facts(_result), do: []

  defp put_iteration_metadata(payload, fact) do
    fact
    |> StepExecutionTrace.fact_iteration_metadata()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> then(&Map.merge(payload, &1))
  end

  defp per_item_duration_us(duration_us, items_total)
       when is_integer(duration_us) and duration_us >= 0 and is_integer(items_total) and
              items_total > 0 do
    max(div(duration_us, items_total), 0)
  end

  defp per_item_duration_us(_duration_us, _items_total), do: 0

  defp truncate_output(output) do
    rendered = inspect(output, pretty: true, limit: :infinity, printable_limit: :infinity)

    if byte_size(rendered) <= @output_summary_limit do
      rendered
    else
      binary_part(rendered, 0, @output_summary_limit) <> "..."
    end
  end

  defp encode_error(%{__struct__: module} = error) do
    %{
      type: module |> Module.split() |> List.last() |> Macro.underscore(),
      message: Exception.message(error),
      details: %{inspect: inspect(error)}
    }
  end

  defp encode_error({type, message, details}) do
    %{
      type: to_string(type),
      message: inspect(message),
      details: %{value: inspect(details)}
    }
  end

  defp encode_error({type, message}) do
    %{
      type: to_string(type),
      message: inspect(message),
      details: %{}
    }
  end

  defp encode_error(type) when is_atom(type) do
    %{type: Atom.to_string(type), message: Atom.to_string(type), details: %{}}
  end

  defp encode_error(message) when is_binary(message) do
    %{type: "runtime_error", message: message, details: %{}}
  end

  defp encode_error(error) do
    %{type: "runtime_error", message: inspect(error), details: %{}}
  end

  defp workflow_output(%Workflow{} = workflow) do
    case workflow_result_step_ids(workflow) do
      [] ->
        Workflow.raw_productions(workflow)

      step_ids ->
        Enum.flat_map(step_ids, &Workflow.raw_productions(workflow, &1))
    end
  end

  defp workflow_result_step_ids(%Workflow{} = workflow) do
    case Map.get(workflow, :fizz_metadata, %{}) do
      %{result_step_ids: step_ids} when is_list(step_ids) -> Enum.uniq(step_ids)
      _ -> []
    end
  end

  defp workflow_result_step_ids(_workflow), do: []

  defp broadcast(run_id, event) do
    Phoenix.PubSub.broadcast(Fizz.PubSub, "workflow_run:#{run_id}", event)
  end

  defp via_tuple(registry, run_id) do
    {:via, Registry, {registry, run_id}}
  end
end
