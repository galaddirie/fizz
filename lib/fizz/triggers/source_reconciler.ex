defmodule Fizz.Triggers.SourceReconciler do
  @moduledoc """
  Reconciles durable trigger sources into supervised poller processes.
  """

  use GenServer

  alias Fizz.Triggers
  alias Fizz.Triggers.SourcePoller

  require Logger

  @default_interval_ms :timer.seconds(30)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      supervisor: Keyword.get(opts, :supervisor, Fizz.Triggers.SourceSupervisor)
    }

    {:ok, state, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    reconcile(state)
    schedule_reconcile(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile(state)
    schedule_reconcile(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("trigger source reconciler ignoring message: #{inspect(message)}")
    {:noreply, state}
  end

  defp reconcile(state) do
    [kind: :polling]
    |> Triggers.list_active_sources()
    |> Enum.each(&ensure_poller(&1.id, state.supervisor))
  end

  defp ensure_poller(source_id, supervisor) do
    case Registry.lookup(Fizz.Triggers.SourceRegistry, source_id) do
      [{_pid, _value}] ->
        :ok

      [] ->
        case DynamicSupervisor.start_child(supervisor, {SourcePoller, source_id: source_id}) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            Logger.warning("failed to start trigger source poller: #{inspect(reason)}")
        end
    end
  end

  defp schedule_reconcile(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :reconcile, interval_ms)
  end
end
