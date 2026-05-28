defmodule Fizz.Workflows.LeaseManager do
  @moduledoc false

  use GenServer

  alias Fizz.Repo

  @lease_ttl_ms 30_000
  @renew_interval_ms 10_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec acquire(String.t(), keyword()) :: {:ok, integer()} | {:error, term()}
  def acquire(run_id, opts \\ []) do
    GenServer.call(server_name(opts), {:acquire, run_id})
  end

  @spec release(String.t(), keyword()) :: :ok | {:error, term()}
  def release(run_id, opts \\ []) do
    GenServer.call(server_name(opts), {:release, run_id})
  end

  @spec renew(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def renew(opts \\ []) do
    GenServer.call(server_name(opts), :renew)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      repo: Keyword.get(opts, :repo, Repo),
      owner_node: Keyword.get(opts, :owner_node, Atom.to_string(node())),
      lease_table: Keyword.get(opts, :lease_table, "workflow_run_leases"),
      lease_ttl_ms: Keyword.get(opts, :lease_ttl_ms, @lease_ttl_ms),
      renew_interval_ms: Keyword.get(opts, :renew_interval_ms, @renew_interval_ms),
      held_runs: MapSet.new()
    }

    schedule_renewal(state.renew_interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, run_id}, _from, state) do
    reply =
      case do_acquire(run_id, state) do
        {:ok, fence_token} ->
          {:ok, fence_token}

        {:error, reason} ->
          {:error, reason}
      end

    new_state =
      case reply do
        {:ok, _fence_token} -> %{state | held_runs: MapSet.put(state.held_runs, run_id)}
        _ -> state
      end

    {:reply, reply, new_state}
  end

  def handle_call({:release, run_id}, _from, state) do
    reply = do_release(run_id, state)
    new_state = %{state | held_runs: MapSet.delete(state.held_runs, run_id)}
    {:reply, reply, new_state}
  end

  def handle_call(:renew, _from, state) do
    {result, state} = renew_leases(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:renew_leases, state) do
    {_result, state} = renew_leases(state)
    schedule_renewal(state.renew_interval_ms)
    {:noreply, state}
  end

  defp do_acquire(run_id, state) do
    sql = """
    UPDATE #{state.lease_table}
    SET owner_node = $2,
        fence_token = fence_token + 1,
        lease_expiry = NOW() + ($3 * interval '1 millisecond')
    WHERE run_id = $1
      AND (lease_expiry < NOW() OR owner_node = $2)
    RETURNING fence_token
    """

    state.repo.transaction(fn ->
      case Ecto.Adapters.SQL.query(state.repo, sql, [
             dump_uuid(run_id),
             state.owner_node,
             state.lease_ttl_ms
           ]) do
        {:ok, %{rows: [[fence_token]]}} ->
          fence_token

        {:ok, %{num_rows: 0}} ->
          state.repo.rollback(:lease_unavailable)

        {:error, reason} ->
          state.repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, fence_token} -> {:ok, fence_token}
      {:error, :lease_unavailable} -> {:error, :lease_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_release(run_id, state) do
    sql = """
    UPDATE #{state.lease_table}
    SET owner_node = NULL,
        lease_expiry = NOW() - interval '1 second'
    WHERE run_id = $1 AND owner_node = $2
    """

    case Ecto.Adapters.SQL.query(state.repo, sql, [dump_uuid(run_id), state.owner_node]) do
      {:ok, %{num_rows: 0}} -> {:error, :not_owner}
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp renew_leases(state) do
    if MapSet.size(state.held_runs) == 0 do
      {{:ok, []}, state}
    else
      run_ids = MapSet.to_list(state.held_runs)

      sql = """
      UPDATE #{state.lease_table}
      SET lease_expiry = NOW() + ($3 * interval '1 millisecond')
      WHERE run_id = ANY($1::uuid[])
        AND owner_node = $2
        AND lease_expiry >= NOW()
      RETURNING run_id
      """

      dumped_run_ids = Enum.map(run_ids, &dump_uuid/1)

      case Ecto.Adapters.SQL.query(state.repo, sql, [
             dumped_run_ids,
             state.owner_node,
             state.lease_ttl_ms
           ]) do
        {:ok, %{rows: rows}} ->
          renewed_ids = Enum.map(rows, fn [run_id] -> load_uuid(run_id) end)
          lost_runs = MapSet.difference(state.held_runs, MapSet.new(renewed_ids))
          state = %{state | held_runs: MapSet.difference(state.held_runs, lost_runs)}
          {{:ok, renewed_ids}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end
    end
  end

  defp schedule_renewal(interval_ms) do
    Process.send_after(self(), :renew_leases, interval_ms)
  end

  defp server_name(opts), do: Keyword.get(opts, :server, __MODULE__)

  defp dump_uuid(run_id) when is_binary(run_id), do: Ecto.UUID.dump!(run_id)
  defp dump_uuid(run_id), do: run_id

  defp load_uuid(run_id) when is_binary(run_id) and byte_size(run_id) == 16,
    do: Ecto.UUID.load!(run_id)

  defp load_uuid(run_id), do: run_id
end
