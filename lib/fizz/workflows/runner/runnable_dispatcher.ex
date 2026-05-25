defmodule Fizz.Workflows.Runner.RunnableDispatcher do
  @moduledoc """
  Global GenStage producer for workflow runnable execution.

  Workers enqueue runnable requests here instead of starting runnable tasks
  directly. Demand from bounded consumers controls global runnable concurrency,
  while the producer keeps per-run queues and dispatches in a fair rotation.
  """

  use GenStage

  alias Fizz.Workflows.Runner.RunnableDispatcher.Request
  alias Runic.Workflow.Runnable

  defstruct queues: %{},
            run_order: :queue.new(),
            pending_demand: 0,
            worker_refs: %{},
            ref_workers: %{},
            last_run_id: nil

  @type t :: %__MODULE__{
          queues: %{optional(String.t()) => :queue.queue(Request.t())},
          run_order: :queue.queue(String.t()),
          pending_demand: non_neg_integer(),
          worker_refs: %{optional(pid()) => reference()},
          ref_workers: %{optional(reference()) => pid()},
          last_run_id: String.t() | nil
        }

  @doc """
  Starts the dispatcher producer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenStage.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Enqueues a runnable for demand-driven execution.
  """
  @spec enqueue(GenStage.stage(), String.t(), pid(), Runnable.t()) :: {:ok, reference()}
  def enqueue(dispatcher \\ __MODULE__, run_id, worker_pid, %Runnable{} = runnable)
      when is_binary(run_id) and is_pid(worker_pid) do
    request = Request.new(run_id, worker_pid, runnable)

    case GenStage.call(dispatcher, {:enqueue, request}, :infinity) do
      :ok -> {:ok, request.ref}
    end
  end

  @doc """
  Removes queued requests for a worker.

  Running requests are cancelled by consumers when the worker process exits.
  """
  @spec cancel_worker(GenStage.stage(), pid()) :: :ok
  def cancel_worker(dispatcher \\ __MODULE__, worker_pid) when is_pid(worker_pid) do
    GenStage.cast(dispatcher, {:cancel_worker, worker_pid})
  end

  @impl true
  def init(_opts) do
    {:producer, %__MODULE__{}}
  end

  @impl true
  def handle_call({:enqueue, %Request{} = request}, from, state) do
    state =
      state
      |> monitor_worker(request.worker_pid)
      |> enqueue_request(request)

    GenStage.reply(from, :ok)
    dispatch_events(state)
  end

  @impl true
  def handle_cast({:cancel_worker, worker_pid}, state) when is_pid(worker_pid) do
    {:noreply, [], drop_worker(state, worker_pid)}
  end

  @impl true
  def handle_demand(incoming_demand, state) when incoming_demand > 0 do
    %{state | pending_demand: state.pending_demand + incoming_demand}
    |> dispatch_events()
  end

  @impl true
  def handle_info({:DOWN, ref, :process, worker_pid, _reason}, state) do
    case Map.get(state.ref_workers, ref) do
      ^worker_pid ->
        {:noreply, [], drop_worker(state, worker_pid)}

      _other ->
        {:noreply, [], state}
    end
  end

  defp monitor_worker(%__MODULE__{worker_refs: worker_refs} = state, worker_pid) do
    if Map.has_key?(worker_refs, worker_pid) do
      state
    else
      ref = Process.monitor(worker_pid)

      %{
        state
        | worker_refs: Map.put(state.worker_refs, worker_pid, ref),
          ref_workers: Map.put(state.ref_workers, ref, worker_pid)
      }
    end
  end

  defp enqueue_request(%__MODULE__{} = state, %Request{run_id: run_id} = request) do
    queue = Map.get(state.queues, run_id, :queue.new())
    was_empty? = :queue.is_empty(queue)
    queues = Map.put(state.queues, run_id, :queue.in(request, queue))
    run_order = maybe_append_run(state.run_order, run_id, was_empty?)

    %{state | queues: queues, run_order: run_order}
  end

  defp maybe_append_run(run_order, run_id, true), do: :queue.in(run_id, run_order)
  defp maybe_append_run(run_order, _run_id, false), do: run_order

  defp dispatch_events(%__MODULE__{pending_demand: 0} = state) do
    {:noreply, [], state}
  end

  defp dispatch_events(%__MODULE__{} = state) do
    {events, state} = take_events(state, state.pending_demand, [])
    {:noreply, Enum.reverse(events), state}
  end

  defp take_events(%__MODULE__{} = state, 0, events) do
    {events, %{state | pending_demand: 0}}
  end

  defp take_events(%__MODULE__{} = state, demand, events) do
    case pop_next_request(state) do
      {:ok, request, state} ->
        take_events(%{state | pending_demand: demand - 1}, demand - 1, [request | events])

      :empty ->
        {events, %{state | pending_demand: demand}}
    end
  end

  defp pop_next_request(%__MODULE__{} = state) do
    state
    |> rotate_last_run()
    |> do_pop_next_request()
  end

  defp rotate_last_run(%__MODULE__{last_run_id: nil} = state), do: state

  defp rotate_last_run(%__MODULE__{} = state) do
    case :queue.out(state.run_order) do
      {{:value, run_id}, run_order} when run_id == state.last_run_id ->
        if :queue.is_empty(run_order) do
          state
        else
          %{state | run_order: :queue.in(run_id, run_order)}
        end

      {{:value, run_id}, run_order} ->
        %{state | run_order: :queue.in_r(run_id, run_order)}

      {:empty, _run_order} ->
        state
    end
  end

  defp do_pop_next_request(%__MODULE__{} = state) do
    case :queue.out(state.run_order) do
      {{:value, run_id}, run_order} ->
        pop_run_request(%{state | run_order: run_order}, run_id)

      {:empty, _run_order} ->
        :empty
    end
  end

  defp pop_run_request(%__MODULE__{} = state, run_id) do
    case Map.fetch(state.queues, run_id) do
      {:ok, queue} ->
        case :queue.out(queue) do
          {{:value, %Request{} = request}, queue} ->
            queues = put_or_delete_queue(state.queues, run_id, queue)
            run_order = maybe_requeue_run(state.run_order, run_id, queue)

            {:ok, request, %{state | queues: queues, run_order: run_order, last_run_id: run_id}}

          {:empty, _queue} ->
            pop_next_request(%{state | queues: Map.delete(state.queues, run_id)})
        end

      :error ->
        pop_next_request(state)
    end
  end

  defp put_or_delete_queue(queues, run_id, queue) do
    if :queue.is_empty(queue) do
      Map.delete(queues, run_id)
    else
      Map.put(queues, run_id, queue)
    end
  end

  defp maybe_requeue_run(run_order, run_id, queue) do
    if :queue.is_empty(queue) do
      run_order
    else
      :queue.in(run_id, run_order)
    end
  end

  defp drop_worker(%__MODULE__{} = state, worker_pid) do
    state
    |> demonitor_worker(worker_pid)
    |> remove_worker_requests(worker_pid)
  end

  defp demonitor_worker(%__MODULE__{} = state, worker_pid) do
    case Map.pop(state.worker_refs, worker_pid) do
      {nil, worker_refs} ->
        %{state | worker_refs: worker_refs}

      {ref, worker_refs} ->
        Process.demonitor(ref, [:flush])

        %{
          state
          | worker_refs: worker_refs,
            ref_workers: Map.delete(state.ref_workers, ref)
        }
    end
  end

  defp remove_worker_requests(%__MODULE__{} = state, worker_pid) do
    queues =
      state.queues
      |> Enum.reduce(%{}, fn {run_id, queue}, acc ->
        queue = reject_worker(queue, worker_pid)

        if :queue.is_empty(queue) do
          acc
        else
          Map.put(acc, run_id, queue)
        end
      end)

    run_order =
      state.run_order
      |> :queue.to_list()
      |> Enum.filter(&Map.has_key?(queues, &1))
      |> Enum.uniq()
      |> Enum.reduce(:queue.new(), fn run_id, acc -> :queue.in(run_id, acc) end)

    %{state | queues: queues, run_order: run_order}
  end

  defp reject_worker(queue, worker_pid) do
    queue
    |> :queue.to_list()
    |> Enum.reject(&(&1.worker_pid == worker_pid))
    |> Enum.reduce(:queue.new(), fn request, acc -> :queue.in(request, acc) end)
  end
end
