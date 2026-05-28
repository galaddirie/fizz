defmodule Fizz.Workflows.Runner.Worker do
  @moduledoc """
  Internal GenServer that owns the live execution of a single workflow run.

  The worker wraps Runic's three-phase execution model for Fizz:

  1. prepare pending runnables from the current workflow state
  2. dispatch runnable execution through the global GenStage dispatcher
  3. apply completed runnables back through a single-writer boundary

  In addition to the in-memory Runic workflow, the worker coordinates
  checkpointing, run activity timestamps, terminal status updates, and lease
  release on shutdown.
  """

  use GenServer

  alias Fizz.Workflows
  alias Fizz.Workflows.{DurableTimer, SignalInbox}
  alias Fizz.Workflows.Runner.StepRetry
  alias Fizz.Workflows.Runner.RunnableDispatcher
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
  @default_delivery_timeout_ms 30_000
  @output_summary_limit 1_024
  @inspect_collection_limit 50

  defstruct [
    :run_id,
    :workflow,
    :store,
    :fence_token,
    :checkpoint_strategy,
    :max_concurrency,
    :runnable_dispatcher,
    :registry,
    :idle_timeout_ms,
    :idle_timer_ref,
    :status,
    cycle_count: 0,
    active_tasks: %{},
    local_timers: %{},
    retrying_runnables: %{}
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
    pid
    |> deliver_event(event, timeout: :infinity)
    |> legacy_delivery_reply()
  end

  def deliver_event(run_id, event) when is_binary(run_id) do
    run_id
    |> deliver_event(event, timeout: :infinity)
    |> legacy_delivery_reply()
  end

  @doc """
  Delivers an external workflow event with a bounded caller timeout.

  This API distinguishes a caller timeout before the worker accepts the event
  from a worker reply after the event is incorporated or rejected.
  """
  def deliver_event(pid, event, opts) when is_pid(pid) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_delivery_timeout_ms)
    call_deliver_event(pid, event, timeout)
  end

  def deliver_event(run_id, event, opts) when is_binary(run_id) and is_list(opts) do
    case lookup(run_id, opts) do
      nil ->
        {:error, :not_found}

      pid ->
        deliver_event(pid, event, opts)
    end
  end

  defp call_deliver_event(pid, event, timeout) do
    pid
    |> GenServer.call({:deliver_event, event, delivery_deadline(timeout)}, timeout)
    |> normalize_delivery_reply()
  catch
    :exit, {:timeout, _reason} -> {:error, :timeout}
    :exit, {:noproc, _reason} -> {:error, :not_found}
    :exit, reason -> {:error, reason}
  end

  defp normalize_delivery_reply(:ok), do: {:ok, :settled}
  defp normalize_delivery_reply({:ok, :skipped}), do: {:ok, :skipped}
  defp normalize_delivery_reply({:error, reason}), do: {:error, reason}
  defp normalize_delivery_reply(reply), do: {:error, {:unexpected_delivery_reply, reply}}

  defp delivery_deadline(:infinity), do: :infinity

  defp delivery_deadline(timeout) when is_integer(timeout) do
    System.monotonic_time(:millisecond) + timeout
  end

  defp legacy_delivery_reply({:ok, :settled}), do: :ok
  defp legacy_delivery_reply({:ok, :accepted}), do: :ok
  defp legacy_delivery_reply({:ok, :skipped}), do: {:ok, :skipped}
  defp legacy_delivery_reply({:error, reason}), do: {:error, reason}

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
  Stops an idle worker for passivation.

  Returns `{:error, :active_work}` when the worker still has active, queued, or
  immediately dispatchable work and must stay hot.
  """
  def passivate(target, opts \\ [])

  def passivate(pid, opts) when is_pid(pid) do
    GenServer.call(pid, {:passivate, opts}, :infinity)
  end

  def passivate(run_id, opts) when is_binary(run_id) and is_list(opts) do
    case lookup(run_id, opts) do
      nil ->
        {:error, :not_found}

      pid ->
        passivate(pid, opts)
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
      runnable_dispatcher:
        Keyword.get(opts, :runnable_dispatcher, Fizz.Workflows.Runner.RunnableDispatcher),
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

  def handle_call({:passivate, opts}, _from, state) do
    case passivation_blocker(state) do
      :none ->
        state =
          state
          |> cancel_idle_timeout()
          |> maybe_checkpoint_before_stop(opts)

        {:stop, :normal, :ok, state}

      reason ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:deliver_event, event, deadline}, _from, state) do
    case delivery_deadline_expired?(deadline) do
      true ->
        {:reply, {:error, :timeout}, state}

      false ->
        do_deliver_event(event, state)
    end
  end

  def handle_call({:deliver_event, event}, _from, state) do
    do_deliver_event(event, state)
  end

  defp delivery_deadline_expired?(:infinity), do: false

  defp delivery_deadline_expired?(deadline) do
    System.monotonic_time(:millisecond) >= deadline
  end

  defp do_deliver_event(event, state) do
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
  def handle_info({RunnableDispatcher, {:started, ref, consumer_pid, started_at_us}}, state)
      when is_reference(ref) and is_pid(consumer_pid) do
    case Map.fetch(state.active_tasks, ref) do
      {:ok, task_state} ->
        task_state =
          task_state
          |> Map.put(:consumer_pid, consumer_pid)
          |> Map.put(:dispatched_at_us, started_at_us)
          |> Map.put(:status, :running)

        state =
          state
          |> put_in([Access.key!(:active_tasks), ref], task_state)
          |> append_runnable_dispatched_event(task_state)

        maybe_broadcast_step_started(state, task_state)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({RunnableDispatcher, {:completed, ref, %Runnable{} = executed}}, state)
      when is_reference(ref) do
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

  def handle_info({RunnableDispatcher, {:failed, ref, reason}}, state) when is_reference(ref) do
    case Map.pop(state.active_tasks, ref) do
      {nil, _active_tasks} ->
        {:noreply, state}

      {task_state, active_tasks} ->
        failed_runnable = Runnable.fail(task_state.runnable, reason)

        case handle_failed_task(
               %{state | active_tasks: active_tasks},
               failed_runnable,
               task_state
             ) do
          {:continue, next_state} ->
            {:noreply, next_state}

          {:stop, next_state} ->
            {:stop, :normal, next_state}

          {:error, retry_reason, next_state} ->
            {:stop, :normal, fail_and_stop(next_state, retry_reason)}
        end
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
    # fail_run/2 owns terminal cleanup and handles already-failed runs, so we
    # just call it and handle errors gracefully.
    case Workflows.fail_run(state.run_id, :worker_terminated) do
      {:ok, _run} -> :ok
      {:error, _reason} -> :ok
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
    local_slots = max(state.max_concurrency - map_size(state.active_tasks), 0)

    active_runnable_ids =
      Map.values(state.active_tasks) |> Enum.map(& &1.runnable.id) |> MapSet.new()

    retrying_runnable_ids =
      state.retrying_runnables
      |> Map.keys()
      |> MapSet.new()

    unavailable_runnable_ids = MapSet.union(active_runnable_ids, retrying_runnable_ids)

    pending_runnables = Enum.reject(runnables, &MapSet.member?(unavailable_runnable_ids, &1.id))

    pending_runnables
    |> Enum.take(local_slots)
    |> Enum.reduce(state, fn runnable, acc -> dispatch_runnable(acc, runnable) end)
  end

  defp dispatch_runnable(state, %Runnable{} = runnable, attempt \\ 0)
       when is_integer(attempt) and attempt >= 0 do
    case RunnableDispatcher.enqueue(state.runnable_dispatcher, state.run_id, self(), runnable) do
      {:ok, ref} ->
        task_state = %{
          attempt: attempt,
          consumer_pid: nil,
          dispatched_at_us: nil,
          runnable: runnable,
          status: :queued
        }

        %{state | active_tasks: Map.put(state.active_tasks, ref, task_state)}
    end
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
    if StepRetry.timer?(timer) do
      process_step_retry_timer(state, timer)
    else
      process_delayed_timer(state, timer)
    end
  end

  defp process_event(state, _event), do: {:error, :unsupported_event, state}

  defp process_delayed_timer(state, %DurableTimer{} = timer) do
    with {:ok, runnable} <- delayed_timer_runnable(state.workflow, timer) do
      state =
        state
        |> cancel_idle_timeout()
        |> ensure_running_state()
        |> drop_local_timer(timer.id)
        |> append_delayed_runnable_result_event(runnable, timer)
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

  defp process_step_retry_timer(state, %DurableTimer{} = timer) do
    with {:ok, %{runnable: runnable, attempt: attempt}} <-
           StepRetry.decode_timer(timer, state.workflow) do
      state =
        state
        |> cancel_idle_timeout()
        |> ensure_running_state()
        |> drop_local_timer(timer.id)
        |> drop_retrying_runnable(runnable.id)
        |> dispatch_runnable(runnable, attempt)

      _ = Workflows.touch_run_activity(state.run_id)
      _ = Workflows.clear_run_error(state.run_id)
      :ok = Workflows.mark_timer_fired(timer.id)

      {:continue, state}
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp handle_completed_task(state, %Runnable{status: :failed} = executed, task_state) do
    handle_failed_task(state, executed, task_state)
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

  defp handle_failed_task(state, %Runnable{status: :failed} = executed, task_state) do
    state =
      state
      |> append_runnable_result_event(executed, task_state)
      |> bump_cycle_count()

    _ = Workflows.touch_run_activity(state.run_id)

    case schedule_step_retry(state, executed, task_state) do
      {:ok, retry_state} ->
        {:continue, retry_state}

      :halt ->
        state = apply_runnable(state, executed)
        {:stop, fail_and_stop(state, executed.error)}

      {:error, reason, retry_state} ->
        {:error, reason, apply_runnable(retry_state, executed)}
    end
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
        |> do_checkpoint()
        |> maybe_schedule_local_timer(timer)
        |> mark_sleeping_state()

      _ = Workflows.touch_run_activity(state.run_id)

      dispatch_cycle(state)
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp schedule_step_retry(state, %Runnable{} = failed_runnable, task_state) do
    case StepRetry.next_retry(failed_runnable, failed_runnable.error, task_state.attempt) do
      {:ok, retry} ->
        create_step_retry_timer(state, failed_runnable, retry)

      :halt ->
        :halt
    end
  end

  defp create_step_retry_timer(state, %Runnable{} = failed_runnable, retry) do
    fire_at = DateTime.add(DateTime.utc_now(), retry.delay_ms, :millisecond)

    with {:ok, timer} <-
           Workflows.create_timer(
             state.run_id,
             StepRetry.retry_step_id(failed_runnable),
             fire_at,
             timer_name: StepRetry.timer_name(failed_runnable),
             payload: retry.timer_payload
           ),
         {:ok, _run} <-
           Workflows.record_run_retry(
             state.run_id,
             StepRetry.run_error_payload(retry, fire_at),
             sleep?: map_size(state.active_tasks) == 0
           ) do
      state =
        state
        |> put_retrying_runnable(failed_runnable.id, timer.id)
        |> maybe_schedule_local_timer(timer)
        |> maybe_mark_retry_sleeping()
        |> maybe_checkpoint(%{cycle_count: state.cycle_count, status: :running})

      {:ok, state}
    else
      {:error, reason} -> {:error, reason, state}
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

  defp append_runnable_dispatched_event(state, task_state) do
    event = %RunnableDispatched{
      runnable_id: task_state.runnable.id,
      node_name: Map.get(task_state.runnable.node, :name),
      node_hash: Map.get(task_state.runnable.node, :hash),
      input_fact: task_state.runnable.input_fact,
      dispatched_at:
        System.convert_time_unit(task_state.dispatched_at_us, :microsecond, :millisecond),
      policy: SchedulerPolicy.default_policy(),
      attempt: task_state.attempt
    }

    %{state | workflow: Workflow.append_runnable_events(state.workflow, [event])}
  end

  defp append_runnable_result_event(state, %Runnable{status: :completed} = runnable, task_state) do
    duration_us = duration_us(task_state)

    event = %RunnableCompleted{
      runnable_id: runnable.id,
      node_hash: Map.get(runnable.node, :hash),
      result_fact: runnable.result,
      completed_at: System.monotonic_time(:millisecond),
      attempt: task_state.attempt,
      duration_ms: duration_ms(duration_us),
      duration_us: duration_us
    }

    maybe_broadcast_step_completed(state, runnable, duration_us, task_state.attempt)

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
      attempts: task_state.attempt + 1,
      failure_action: :halt
    }

    maybe_broadcast_step_failed(state, runnable, duration_us, task_state.attempt)

    %{state | workflow: Workflow.append_runnable_events(state.workflow, [event])}
  end

  defp append_runnable_result_event(state, _runnable, _task_state), do: state

  defp append_delayed_runnable_result_event(
         state,
         %Runnable{} = runnable,
         %DurableTimer{} = timer
       ) do
    duration_us = DateTime.diff(DateTime.utc_now(), timer.inserted_at, :microsecond)
    duration_ms = div(duration_us, 1000)

    event = %RunnableCompleted{
      runnable_id: runnable.id,
      node_hash: Map.get(runnable.node, :hash),
      result_fact: runnable.result,
      completed_at: System.monotonic_time(:millisecond),
      attempt: 0,
      duration_ms: duration_ms,
      duration_us: duration_us
    }

    maybe_broadcast_step_completed(state, runnable, duration_us, 0)

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

    # 4. Mark run as failed in DB and run terminal cleanup — log on error
    case Workflows.fail_run(state.run_id, reason) do
      {:ok, _run} -> :ok
      {:error, fail_reason} -> Logger.error("fail_run failed: #{inspect(fail_reason)}")
    end

    state
  end

  defp passivation_blocker(%__MODULE__{active_tasks: active_tasks})
       when map_size(active_tasks) > 0 do
    :active_work
  end

  defp passivation_blocker(%__MODULE__{retrying_runnables: retrying_runnables})
       when map_size(retrying_runnables) > 0 do
    :active_work
  end

  defp passivation_blocker(%__MODULE__{local_timers: local_timers})
       when map_size(local_timers) > 0 do
    :active_work
  end

  defp passivation_blocker(%__MODULE__{} = state) do
    case Workflow.is_runnable?(state.workflow) do
      true -> :active_work
      false -> :none
    end
  end

  defp shutdown_active_tasks(%__MODULE__{} = state) do
    _ = RunnableDispatcher.cancel_worker(state.runnable_dispatcher, self())
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

  defp put_retrying_runnable(
         %__MODULE__{retrying_runnables: retrying_runnables} = state,
         runnable_id,
         timer_id
       ) do
    %{state | retrying_runnables: Map.put(retrying_runnables, runnable_id, timer_id)}
  end

  defp drop_retrying_runnable(
         %__MODULE__{retrying_runnables: retrying_runnables} = state,
         runnable_id
       ) do
    %{state | retrying_runnables: Map.delete(retrying_runnables, runnable_id)}
  end

  defp maybe_mark_retry_sleeping(%__MODULE__{active_tasks: active_tasks} = state)
       when map_size(active_tasks) == 0 do
    state
    |> maybe_broadcast_status_change(:sleeping)
    |> Map.put(:status, :sleeping)
  end

  defp maybe_mark_retry_sleeping(%__MODULE__{} = state), do: state

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

  defp maybe_broadcast_step_started(state, %{runnable: %Runnable{} = runnable} = task_state) do
    with {:ok, step_id} <- runnable_step_id(runnable) do
      payload =
        %{
          run_id: state.run_id,
          runnable_id: runnable.id,
          step_id: step_id,
          attempt: task_state.attempt,
          input_summary: summarize_value(runnable.input_fact.value),
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

  defp maybe_broadcast_step_completed(state, %Runnable{} = runnable, duration_us, attempt) do
    case splitter_iteration_payloads(state.run_id, runnable, duration_us, attempt) do
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
              attempt: attempt,
              input_summary: summarize_value(runnable.input_fact.value),
              input_fact_hash: runnable.input_fact.hash,
              output_item_count: output_item_count(output),
              output_fact_hash: output_fact_hash(runnable),
              output_summary: summarize_value(output),
              duration_us: duration_us,
              completed_at: DateTime.utc_now()
            }
            |> put_iteration_metadata(runnable.input_fact)

          _ = broadcast(state.run_id, {:step_completed, payload})

          :ok
        end
    end
  end

  defp maybe_broadcast_step_failed(state, %Runnable{} = runnable, duration_us, attempt) do
    with {:ok, step_id} <- runnable_step_id(runnable) do
      payload =
        %{
          run_id: state.run_id,
          runnable_id: runnable.id,
          step_id: step_id,
          attempt: attempt,
          input_summary: summarize_value(runnable.input_fact.value),
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
         duration_us,
         attempt
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
            attempt: attempt,
            input_summary: summarize_value(runnable.input_fact.value),
            input_fact_hash: runnable.input_fact.hash,
            output_item_count: 1,
            output_fact_hash: fact.hash,
            output_summary: summarize_value(fact.value),
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

  defp splitter_iteration_payloads(_run_id, _runnable, _duration_us, _attempt), do: :error

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

  defp summarize_value(value) do
    rendered =
      inspect(value,
        pretty: true,
        limit: @inspect_collection_limit,
        printable_limit: @output_summary_limit
      )

    limit_summary(rendered)
  end

  defp summarize_text(value) when is_binary(value), do: limit_summary(value)
  defp summarize_text(value), do: summarize_value(value)

  defp limit_summary(value) when byte_size(value) <= @output_summary_limit, do: value

  defp limit_summary(value) do
    value
    |> binary_part(0, @output_summary_limit)
    |> valid_utf8_prefix()
    |> Kernel.<>("...")
  end

  defp valid_utf8_prefix(value) do
    cond do
      String.valid?(value) ->
        value

      byte_size(value) == 0 ->
        value

      true ->
        value
        |> binary_part(0, byte_size(value) - 1)
        |> valid_utf8_prefix()
    end
  end

  defp encode_error(%{__struct__: module} = error) do
    %{
      type: module |> Module.split() |> List.last() |> Macro.underscore(),
      message: error |> Exception.message() |> summarize_text(),
      details: %{inspect: summarize_value(error)}
    }
  end

  defp encode_error({type, message, details}) do
    %{
      type: to_string(type),
      message: summarize_text(message),
      details: %{value: summarize_value(details)}
    }
  end

  defp encode_error({type, message}) do
    %{
      type: to_string(type),
      message: summarize_text(message),
      details: %{}
    }
  end

  defp encode_error(type) when is_atom(type) do
    %{type: Atom.to_string(type), message: Atom.to_string(type), details: %{}}
  end

  defp encode_error(message) when is_binary(message) do
    %{type: "runtime_error", message: summarize_text(message), details: %{}}
  end

  defp encode_error(error) do
    %{type: "runtime_error", message: summarize_value(error), details: %{}}
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
