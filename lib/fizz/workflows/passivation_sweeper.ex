defmodule Fizz.Workflows.PassivationSweeper do
  @moduledoc """
  Periodically passivates idle workflow runs.

  The sweeper scans for runs still marked `:running` or `:sleeping` whose
  `last_active_at` is older than the configured idle threshold. Matching runs
  have their workers stopped, their status updated to `:passivated`, and their
  lease released.

  TODO: Cold-tier checkpoint upload
  """

  use GenServer

  alias Fizz.Workflows
  alias Fizz.Workflows.Runner.Worker

  @default_interval_ms 60_000
  @default_idle_threshold_ms 10 * 60 * 1_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Triggers a sweep immediately.

  Primarily useful in tests and operational tooling.
  """
  def sweep(opts \\ []) do
    GenServer.call(server_name(opts), :sweep, :infinity)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      idle_threshold_ms: Keyword.get(opts, :idle_threshold_ms, @default_idle_threshold_ms),
      worker_opts: Keyword.get(opts, :worker_opts, [])
    }

    schedule_sweep(state.interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    {:reply, do_sweep(state), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    _ = do_sweep(state)
    schedule_sweep(state.interval_ms)
    {:noreply, state}
  end

  defp do_sweep(state) do
    idle_before = DateTime.add(DateTime.utc_now(), -state.idle_threshold_ms, :millisecond)

    passivated_run_ids =
      idle_before
      |> Workflows.list_passivation_candidates()
      |> Enum.reduce([], fn run, acc ->
        _ = Worker.stop(run.id, Keyword.merge([persist: true], state.worker_opts))

        case Workflows.passivate_run(run.id) do
          {:ok, _run} ->
            _ = Workflows.release_run_lease(run.id)
            [run.id | acc]

          {:error, _reason} ->
            acc
        end
      end)
      |> Enum.reverse()

    {:ok, passivated_run_ids}
  end

  defp schedule_sweep(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :sweep, interval_ms)
  end

  defp schedule_sweep(_interval_ms), do: :ok

  defp server_name(opts), do: Keyword.get(opts, :server, __MODULE__)
end
