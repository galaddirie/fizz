defmodule Fizz.Workflows.TimerPoller do
  @moduledoc """
  Polls durable timers, claims due rows with `FOR UPDATE SKIP LOCKED`, and
  routes timer fires back into workflow workers.
  """

  use GenServer

  alias Fizz.Workflows
  alias Fizz.Workflows.DurableTimer

  @default_interval_ms 1_000
  @default_batch_size 50
  @default_claim_ttl_ms 30_000

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
    GenServer.call(server_name(opts), :poll, :infinity)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      claim_ttl_ms: Keyword.get(opts, :claim_ttl_ms, @default_claim_ttl_ms),
      claimed_by: Keyword.get(opts, :claimed_by, "#{Atom.to_string(node())}:timer_poller"),
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
        Enum.reduce(timers, [], fn %DurableTimer{} = timer, acc ->
          case Workflows.deliver_run_event(timer.run_id, {:timer_fired, timer}, state.worker_opts) do
            :ok ->
              :ok = Workflows.mark_timer_fired(timer.id)
              [timer.id | acc]

            {:ok, :skipped} ->
              :ok = Workflows.mark_timer_fired(timer.id)
              [timer.id | acc]

            {:error, _reason} ->
              acc
          end
        end)
        |> Enum.reverse()

      {:ok, fired_timer_ids}
    end
  end

  defp schedule_poll(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :poll, interval_ms)
  end

  defp schedule_poll(_interval_ms), do: :ok

  defp server_name(opts), do: Keyword.get(opts, :server, __MODULE__)
end
