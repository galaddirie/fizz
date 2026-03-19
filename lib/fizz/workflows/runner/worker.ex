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
  alias Fizz.Workflows.LeaseManager
  alias Fizz.Workflows.Store.{CheckpointStrategy, SqliteStore}
  alias Runic.Workflow

  alias Runic.Workflow.{
    Invokable,
    Runnable,
    RunnableCompleted,
    RunnableDispatched,
    RunnableFailed
  }

  alias Runic.Workflow.SchedulerPolicy

  @default_idle_timeout_ms 60_000

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
    active_tasks: %{}
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
  def handle_cast({:run, input}, %__MODULE__{status: :idle} = state) do
    state =
      state
      |> cancel_idle_timeout()
      |> Map.put(:workflow, Workflow.plan_eagerly(state.workflow, input))
      |> Map.put(:status, :running)

    case dispatch_cycle(state) do
      {:continue, next_state} -> {:noreply, next_state}
      {:stop, next_state} -> {:stop, :normal, next_state}
    end
  end

  def handle_cast({:run, _input}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call({:stop, opts}, _from, state) do
    state =
      state
      |> cancel_idle_timeout()
      |> maybe_checkpoint_before_stop(opts)
      |> shutdown_active_tasks()

    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({ref, %Runnable{} = executed}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.active_tasks, ref) do
      {nil, _active_tasks} ->
        {:noreply, state}

      {task_state, active_tasks} ->
        state =
          state
          |> Map.put(:active_tasks, active_tasks)
          |> append_runnable_result_event(executed, task_state)
          |> apply_runnable(executed)
          |> bump_cycle_count()

        _ = Workflows.touch_run_activity(state.run_id)

        case executed.status do
          :failed ->
            {:stop, :normal, fail_and_stop(state, executed.error)}

          _ ->
            state = maybe_checkpoint(state, %{cycle_count: state.cycle_count, status: :running})

            case dispatch_cycle(state) do
              {:continue, next_state} -> {:noreply, next_state}
              {:stop, next_state} -> {:stop, :normal, next_state}
            end
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
        {:running, 0} -> do_checkpoint(state)
        _ -> state
      end

    {:noreply, schedule_idle_timeout(state)}
  end

  @impl true
  def terminate(_reason, state) do
    state
    |> cancel_idle_timeout()
    |> shutdown_active_tasks()

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
        {:continue, schedule_idle_timeout(state)}

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
    dispatched_at = System.monotonic_time(:millisecond)

    task =
      Task.Supervisor.async_nolink(
        state.task_supervisor,
        __MODULE__,
        :execute_runnable,
        [runnable]
      )

    task_state = %{
      dispatched_at: dispatched_at,
      pid: task.pid,
      runnable: runnable
    }

    event = %RunnableDispatched{
      runnable_id: runnable.id,
      node_name: Map.get(runnable.node, :name),
      node_hash: Map.get(runnable.node, :hash),
      input_fact: runnable.input_fact,
      dispatched_at: dispatched_at,
      policy: SchedulerPolicy.default_policy(),
      attempt: 0
    }

    %{
      state
      | workflow: Workflow.append_runnable_events(state.workflow, [event]),
        active_tasks: Map.put(state.active_tasks, task.ref, task_state)
    }
  end

  defp append_runnable_result_event(state, %Runnable{status: :completed} = runnable, task_state) do
    event = %RunnableCompleted{
      runnable_id: runnable.id,
      node_hash: Map.get(runnable.node, :hash),
      result_fact: runnable.result,
      completed_at: System.monotonic_time(:millisecond),
      attempt: 0,
      duration_ms: duration_ms(task_state.dispatched_at)
    }

    %{state | workflow: Workflow.append_runnable_events(state.workflow, [event])}
  end

  defp append_runnable_result_event(
         state,
         %Runnable{status: :failed, error: error} = runnable,
         _task_state
       ) do
    event = %RunnableFailed{
      runnable_id: runnable.id,
      node_hash: Map.get(runnable.node, :hash),
      error: error,
      failed_at: System.monotonic_time(:millisecond),
      attempts: 1,
      failure_action: :halt
    }

    %{state | workflow: Workflow.append_runnable_events(state.workflow, [event])}
  end

  defp append_runnable_result_event(state, _runnable, _task_state), do: state

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
    _ = Workflows.complete_run(state.run_id, Workflow.raw_productions(state.workflow))
    _ = release_lease(state.run_id)
    state
  end

  defp fail_and_stop(state, reason) do
    state = do_checkpoint(state)
    _ = Workflows.fail_run(state.run_id, reason)
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

  defp duration_ms(dispatched_at) do
    System.monotonic_time(:millisecond) - dispatched_at
  end

  defp via_tuple(registry, run_id) do
    {:via, Registry, {registry, run_id}}
  end
end
