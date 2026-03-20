defmodule Fizz.Workflows.SignalRouter do
  @moduledoc """
  Accepts signals into the durable inbox and retries pending delivery by
  periodically scanning the inbox.
  """

  use GenServer

  import Ecto.Query

  alias Fizz.Repo
  alias Fizz.Workflows
  alias Fizz.Workflows.SignalInbox

  @default_interval_ms 1_000
  @default_batch_size 50

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :name, __MODULE__)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  Accepts a signal into the durable inbox and attempts delivery immediately.
  """
  def accept_signal(run_id, signal_id, signal_name, payload, opts \\ []) do
    with {:ok, signal} <- Workflows.create_signal_inbox(run_id, signal_id, signal_name, payload) do
      _ = deliver_signal(signal.id, opts)
      Workflows.get_signal(signal.id)
    end
  end

  @doc """
  Triggers an inbox drain immediately.
  """
  def drain(opts \\ []) do
    GenServer.call(server_name(opts), :drain, :infinity)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      worker_opts: Keyword.get(opts, :worker_opts, [])
    }

    schedule_drain(state.interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    {:reply, do_drain(state), state}
  end

  def handle_call({:deliver_signal, signal_row_id, extra_opts}, _from, state) do
    opts = Keyword.merge(state.worker_opts, extra_opts)
    {:reply, deliver_signal(signal_row_id, worker_opts: opts), state}
  end

  @impl true
  def handle_info(:drain, state) do
    _ = do_drain(state)
    schedule_drain(state.interval_ms)
    {:noreply, state}
  end

  defp do_drain(state) do
    processed_ids =
      state.batch_size
      |> Workflows.list_pending_signal_ids()
      |> Enum.reduce([], fn signal_row_id, acc ->
        case deliver_signal(signal_row_id, worker_opts: state.worker_opts) do
          {:ok, :delivered} -> [signal_row_id | acc]
          {:ok, :skipped} -> [signal_row_id | acc]
          _ -> acc
        end
      end)
      |> Enum.reverse()

    {:ok, processed_ids}
  end

  defp deliver_signal(signal_row_id, opts) when is_binary(signal_row_id) do
    case Keyword.get(opts, :server) do
      nil ->
        do_deliver_signal(signal_row_id, Keyword.get(opts, :worker_opts, []))

      server ->
        GenServer.call(
          server,
          {:deliver_signal, signal_row_id, Keyword.drop(opts, [:server])},
          :infinity
        )
    end
  end

  defp do_deliver_signal(signal_row_id, worker_opts) do
    case Repo.one(
           from(signal in SignalInbox,
             where: signal.id == ^signal_row_id and signal.status == :pending
           )
         ) do
      nil ->
        {:ok, :noop}

      %SignalInbox{} = signal ->
        case Workflows.deliver_run_event(signal.run_id, {:signal, signal}, worker_opts) do
          :ok ->
            :ok = Workflows.mark_signal_delivered(signal.id)
            {:ok, :delivered}

          {:ok, :skipped} ->
            :ok = Workflows.mark_signal_skipped(signal.id)
            {:ok, :skipped}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp schedule_drain(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :drain, interval_ms)
  end

  defp schedule_drain(_interval_ms), do: :ok

  defp server_name(opts), do: Keyword.get(opts, :server, __MODULE__)
end
