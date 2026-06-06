defmodule Fizz.Workflows.Runner.RunnableConsumer do
  @moduledoc """
  Bounded GenStage consumer that executes one runnable at a time.
  """

  use GenStage

  alias Fizz.Workflows.Runner.Worker
  alias Fizz.Workflows.Runner.RunnableDispatcher
  alias Fizz.Workflows.Runner.RunnableDispatcher.Request
  alias Runic.Workflow.Runnable

  defstruct [
    :producer_from,
    :producer,
    :task_supervisor,
    :current
  ]

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    producer = Keyword.get(opts, :producer, RunnableDispatcher)

    state = %__MODULE__{
      producer: producer,
      task_supervisor: Keyword.get(opts, :task_supervisor, Fizz.Workflows.Runner.TaskSupervisor)
    }

    {:consumer, state, subscribe_to: [{producer, max_demand: 1, min_demand: 0}]}
  end

  @impl true
  def handle_subscribe(:producer, _opts, from, state) do
    GenStage.ask(from, 1)
    {:manual, %{state | producer_from: from}}
  end

  @impl true
  def handle_cancel(_reason, _from, state) do
    {:noreply, [], state}
  end

  @impl true
  def handle_events([%Request{} = request], _from, %{current: nil} = state) do
    {:noreply, [], start_request(state, request)}
  end

  @impl true
  def handle_info({ref, %Runnable{} = executed}, %{current: %{task_ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    send_completed(state.current.request, executed)

    {:noreply, [], finish_request(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{current: %{task_ref: ref}} = state
      ) do
    send_failed(state.current.request, {:task_crashed, reason})
    {:noreply, [], finish_request(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{current: %{worker_ref: ref}} = state
      ) do
    terminate_current_task(state)
    Process.demonitor(state.current.task_ref, [:flush])

    {:noreply, [], finish_request(state)}
  end

  def handle_info(_message, state) do
    {:noreply, [], state}
  end

  defp start_request(%__MODULE__{} = state, %Request{} = request) do
    worker_ref = Process.monitor(request.worker_pid)
    started_at_us = System.monotonic_time(:microsecond)
    send_started(request, started_at_us)

    case start_task(state, request) do
      {:ok, task} ->
        %{
          state
          | current: %{
              request: request,
              started_at_us: started_at_us,
              task_pid: task.pid,
              task_ref: task.ref,
              worker_ref: worker_ref
            }
        }

      {:error, reason} ->
        Process.demonitor(worker_ref, [:flush])
        send_failed(request, {:task_start_failed, reason})
        ask_next(%{state | current: nil})
    end
  end

  defp start_task(%__MODULE__{} = state, %Request{} = request) do
    task =
      Task.Supervisor.async_nolink(
        state.task_supervisor,
        Worker,
        :execute_runnable,
        [request.runnable]
      )

    {:ok, task}
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp finish_request(%__MODULE__{} = state) do
    Process.demonitor(state.current.worker_ref, [:flush])
    ask_next(%{state | current: nil})
  end

  defp terminate_current_task(%__MODULE__{
         current: %{task_pid: task_pid},
         task_supervisor: supervisor
       }) do
    _ = Task.Supervisor.terminate_child(supervisor, task_pid)
    :ok
  end

  defp send_started(%Request{} = request, started_at_us) do
    send(
      request.worker_pid,
      {RunnableDispatcher, {:started, request.ref, self(), started_at_us}}
    )
  end

  defp send_completed(%Request{} = request, %Runnable{} = executed) do
    send(request.worker_pid, {RunnableDispatcher, {:completed, request.ref, executed}})
  end

  defp send_failed(%Request{} = request, reason) do
    send(request.worker_pid, {RunnableDispatcher, {:failed, request.ref, reason}})
  end

  defp ask_next(%__MODULE__{producer_from: nil} = state), do: state

  defp ask_next(%__MODULE__{} = state) do
    GenStage.ask(state.producer_from, 1)
    state
  end
end
