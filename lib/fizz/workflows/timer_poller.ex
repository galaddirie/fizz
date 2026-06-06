defmodule Fizz.Workflows.TimerPoller do
  @moduledoc """
  Polls durable timers, claims due rows with `FOR UPDATE SKIP LOCKED`, and
  routes timer fires back into workflow workers.
  """

  use GenServer

  require Logger

  alias Fizz.Workflows
  alias Fizz.Workflows.DurableTimer

  @default_interval_ms 1_000
  @default_batch_size 50
  @default_claim_ttl_ms 30_000
  @default_max_concurrency 10
  @default_delivery_timeout_ms 30_000
  @default_call_timeout_ms :timer.minutes(3)

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
  Triggers a single poll cycle immediately.
  """
  def poll(opts \\ []) do
    GenServer.call(server_name(opts), :poll, call_timeout_ms())
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      claim_ttl_ms: Keyword.get(opts, :claim_ttl_ms, @default_claim_ttl_ms),
      claimed_by: Keyword.get(opts, :claimed_by, "#{Atom.to_string(node())}:timer_poller"),
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      delivery_timeout_ms: Keyword.get(opts, :delivery_timeout_ms, @default_delivery_timeout_ms),
      worker_opts: Keyword.get(opts, :worker_opts, [])
    }

    schedule_poll(state.interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    {:reply, do_poll(state), state}
  end

  @impl true
  def handle_info(:poll, state) do
    _ = do_poll(state)
    schedule_poll(state.interval_ms)
    {:noreply, state}
  end

  defp do_poll(state) do
    now = DateTime.utc_now()
    {:ok, _count} = Workflows.recover_stale_timers(now: now, claim_ttl_ms: state.claim_ttl_ms)

    with {:ok, timers} <-
           Workflows.claim_due_timers(
             now: now,
             limit: state.batch_size,
             claimed_by: state.claimed_by
           ) do
      fired_timer_ids =
        timers
        |> Task.async_stream(
          &deliver_timer(&1, state.worker_opts),
          max_concurrency: state.max_concurrency,
          timeout: state.delivery_timeout_ms,
          on_timeout: :kill_task
        )
        |> Enum.reduce([], fn
          {:ok, {:ok, timer_id}}, acc -> [timer_id | acc]
          _result, acc -> acc
        end)
        |> Enum.reverse()

      {:ok, fired_timer_ids}
    end
  end

  defp deliver_timer(%DurableTimer{} = timer, worker_opts) do
    case Workflows.deliver_run_event(timer.run_id, {:timer_fired, timer}, worker_opts) do
      :ok ->
        :ok = Workflows.mark_timer_fired(timer.id)
        {:ok, timer.id}

      {:ok, :skipped} ->
        :ok = Workflows.mark_timer_fired(timer.id)
        {:ok, timer.id}

      {:error, reason} ->
        _ = Workflows.release_timer_claim(timer.id)

        Logger.error(
          "failed to deliver timer #{timer.id} for run #{timer.run_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp schedule_poll(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :poll, interval_ms)
  end

  defp schedule_poll(_interval_ms), do: :ok

  defp server_name(opts), do: Keyword.get(opts, :server, __MODULE__)

  defp call_timeout_ms do
    Application.get_env(:fizz, __MODULE__, [])
    |> Keyword.get(:call_timeout_ms, @default_call_timeout_ms)
  end
end
