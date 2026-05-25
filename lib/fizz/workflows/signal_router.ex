defmodule Fizz.Workflows.SignalRouter do
  @moduledoc """
  Accepts signals into the durable inbox and retries pending delivery by
  periodically scanning the inbox.
  """

  use GenServer

  alias Fizz.Workflows
  alias Fizz.Workflows.SignalInbox

  @default_interval_ms 1_000
  @default_batch_size 50
  @default_claim_ttl_ms 30_000
  @default_max_concurrency 10
  @default_delivery_timeout_ms 15_000
  @default_call_timeout_ms :timer.minutes(2)

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
    GenServer.call(server_name(opts), :drain, call_timeout_ms())
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      claim_ttl_ms: Keyword.get(opts, :claim_ttl_ms, @default_claim_ttl_ms),
      claimed_by: Keyword.get(opts, :claimed_by, default_claimed_by()),
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      delivery_timeout_ms: Keyword.get(opts, :delivery_timeout_ms, @default_delivery_timeout_ms),
      worker_opts: Keyword.get(opts, :worker_opts, [])
    }

    schedule_drain(state.interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    {:reply, do_drain(state), state}
  end

  @impl true
  def handle_call({:deliver_signal, signal_row_id, extra_opts}, _from, state) do
    opts = Keyword.merge(state.worker_opts, extra_opts)

    result =
      do_claim_and_deliver_signal(signal_row_id, opts,
        claimed_by: state.claimed_by,
        claim_ttl_ms: state.claim_ttl_ms
      )

    {:reply, result, state}
  end

  @impl true
  def handle_info(:drain, state) do
    _ = do_drain(state)
    schedule_drain(state.interval_ms)
    {:noreply, state}
  end

  defp do_drain(state) do
    now = DateTime.utc_now()
    {:ok, _count} = Workflows.recover_stale_signals(now: now, claim_ttl_ms: state.claim_ttl_ms)

    with {:ok, signals} <-
           Workflows.claim_pending_signals(
             now: now,
             limit: state.batch_size,
             claimed_by: state.claimed_by
           ) do
      signals
      |> Task.async_stream(
        &deliver_claimed_signal(&1, state.worker_opts),
        max_concurrency: state.max_concurrency,
        timeout: state.delivery_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.reduce([], fn
        {:ok, {:ok, :delivered, signal_id}}, acc -> [signal_id | acc]
        {:ok, {:ok, :skipped, signal_id}}, acc -> [signal_id | acc]
        _result, acc -> acc
      end)
      |> Enum.reverse()
      |> then(&{:ok, &1})
    end
  end

  defp deliver_signal(signal_row_id, opts) when is_binary(signal_row_id) do
    case Keyword.get(opts, :server) do
      nil ->
        do_claim_and_deliver_signal(signal_row_id, Keyword.get(opts, :worker_opts, []),
          claimed_by: Keyword.get(opts, :claimed_by, default_claimed_by()),
          claim_ttl_ms: Keyword.get(opts, :claim_ttl_ms, @default_claim_ttl_ms)
        )

      server ->
        GenServer.call(
          server,
          {:deliver_signal, signal_row_id, Keyword.drop(opts, [:server])},
          call_timeout_ms()
        )
    end
  end

  defp do_claim_and_deliver_signal(signal_row_id, worker_opts, opts) do
    case Workflows.claim_signal(signal_row_id, opts) do
      {:ok, %SignalInbox{} = signal} -> deliver_claimed_signal(signal, worker_opts)
      {:error, :not_found} -> delivered_or_noop(signal_row_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_claimed_signal(%SignalInbox{} = signal, worker_opts) do
    case Workflows.deliver_run_event(signal.run_id, {:signal, signal}, worker_opts) do
      :ok ->
        :ok = Workflows.mark_signal_delivered(signal.id)
        {:ok, :delivered, signal.id}

      {:ok, :skipped} ->
        :ok = Workflows.mark_signal_skipped(signal.id)
        {:ok, :skipped, signal.id}

      {:error, reason} ->
        _ = Workflows.release_signal_claim(signal.id)
        {:error, reason}
    end
  end

  defp delivered_or_noop(signal_row_id) do
    case Workflows.get_signal(signal_row_id) do
      {:ok, %SignalInbox{status: :delivered}} -> {:ok, :delivered}
      {:ok, %SignalInbox{status: :skipped}} -> {:ok, :skipped}
      _ -> {:ok, :noop}
    end
  end

  defp schedule_drain(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :drain, interval_ms)
  end

  defp schedule_drain(_interval_ms), do: :ok

  defp server_name(opts), do: Keyword.get(opts, :server, __MODULE__)

  defp default_claimed_by, do: "#{Atom.to_string(node())}:signal_router"

  defp call_timeout_ms do
    Application.get_env(:fizz, __MODULE__, [])
    |> Keyword.get(:call_timeout_ms, @default_call_timeout_ms)
  end
end
