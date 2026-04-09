defmodule Fizz.Workflows.PassivationSweeper do
  @moduledoc """
  Periodically passivates idle workflow runs.

  The sweeper scans for runs still marked `:running` or `:sleeping` whose
  `last_active_at` is older than the configured idle threshold. Matching runs
  have their workers stopped, their SQLite files WAL-checkpointed and evicted
  (cold-tier), their status updated to `:passivated`, and their lease released.
  """

  use GenServer

  require Logger

  alias Fizz.Workflows
  alias Fizz.Workflows.Runner.Worker
  alias Fizz.Workflows.Store.{LitestreamManager, Paths, Sqlite}

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
    data_dir =
      opts
      |> Keyword.get(:data_dir)
      |> Kernel.||(Application.get_env(:fizz, :workflow_data_dir, "priv/workflow_data"))
      |> Path.expand()

    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      idle_threshold_ms: Keyword.get(opts, :idle_threshold_ms, @default_idle_threshold_ms),
      worker_opts: Keyword.get(opts, :worker_opts, []),
      data_dir: data_dir,
      litestream_server: Keyword.get(opts, :litestream_server, LitestreamManager)
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
        case prepare_run_for_passivation(run, state) do
          :ok ->
            if LitestreamManager.status(server: state.litestream_server) == :running do
              cold_evict(run, state)
            end

            case Workflows.passivate_run(run.id) do
              {:ok, _run} ->
                _ = Workflows.release_run_lease(run.id)
                [run.id | acc]

              {:error, _reason} ->
                acc
            end

          {:error, reason} ->
            Logger.warning("skipping passivation for run #{run.id}: #{inspect(reason)}")

            acc
        end
      end)
      |> Enum.reverse()

    {:ok, passivated_run_ids}
  end

  defp prepare_run_for_passivation(run, state) do
    case Worker.stop(run.id, Keyword.merge([persist: true], state.worker_opts)) do
      :ok ->
        :ok

      {:error, :not_found} ->
        if checkpoint_available?(run, state) do
          :ok
        else
          {:error, :checkpoint_not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp checkpoint_available?(run, state) do
    db_path = db_path(run, state)

    if File.exists?(db_path) do
      case Sqlite.with_db(db_path, [configure?: false], fn db ->
             match?({:ok, 1}, Sqlite.first_value(db, "SELECT 1 FROM workflow_log LIMIT 1"))
           end) do
        true -> true
        _ -> false
      end
    else
      false
    end
  end

  defp cold_evict(run, state) do
    db_path = db_path(run, state)

    case LitestreamManager.wal_checkpoint(db_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "WAL checkpoint failed for run #{run.id} before cold eviction: #{inspect(reason)}"
        )
    end

    delete_local_files(db_path)
  end

  defp db_path(run, state) do
    Paths.db_path(state.data_dir, run.id, run.workos_organization_id, run.project_id)
  end

  defp delete_local_files(db_path) do
    for file <- [db_path, "#{db_path}-wal", "#{db_path}-shm"],
        File.exists?(file) do
      File.rm(file)
    end

    :ok
  end

  defp schedule_sweep(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :sweep, interval_ms)
  end

  defp schedule_sweep(_interval_ms), do: :ok

  defp server_name(opts), do: Keyword.get(opts, :server, __MODULE__)
end
