defmodule Fizz.Workflows.Store.SqliteStore do
  @moduledoc false

  @behaviour Runic.Runner.Store
  use GenServer

  alias Fizz.Repo
  alias Fizz.Workflows.Store.Paths
  alias Fizz.Workflows.Store.Sqlite
  alias Fizz.Workflows.Store.SqliteMigrations
  alias Fizz.Workflows.Store.StaleOwnerError
  alias Runic.Workflow.Events.FactProduced

  @meta_entries ~w(run_id org_id project_id)a
  @fact_lookup_chunk_size 250

  @type state :: %{
          data_dir: String.t(),
          org_id: String.t(),
          project_id: String.t(),
          fence_token: integer(),
          repo: module(),
          lease_table: String.t(),
          run_id: String.t() | nil,
          db_path: String.t() | nil
        }

  def start_link(opts) do
    runner_name = Keyword.get(opts, :runner_name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: Module.concat(runner_name, Store))
  end

  def child_spec(opts) do
    runner_name = Keyword.get(opts, :runner_name, __MODULE__)

    %{
      id: {__MODULE__, runner_name},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @impl GenServer
  def init(opts), do: {:ok, opts}

  @impl Runic.Runner.Store
  def init_store(opts) do
    data_dir =
      opts
      |> Keyword.get(
        :data_dir,
        Application.get_env(:fizz, :workflow_data_dir, "priv/workflow_data")
      )
      |> Path.expand()

    org_id = Keyword.get(opts, :org_id, Keyword.get(opts, :workos_organization_id))
    project_id = Keyword.get(opts, :project_id)

    with {:ok, org_id} <- present_string(org_id, :org_id),
         {:ok, project_id} <- present_string(project_id, :project_id) do
      run_id = Keyword.get(opts, :run_id)

      {:ok,
       %{
         data_dir: data_dir,
         org_id: org_id,
         project_id: project_id,
         fence_token: Keyword.get(opts, :fence_token, 0),
         repo: Keyword.get(opts, :repo, Repo),
         lease_table: Keyword.get(opts, :lease_table, "workflow_run_leases"),
         run_id: run_id,
         db_path:
           if(is_binary(run_id),
             do: Paths.db_path(data_dir, run_id, org_id, project_id),
             else: nil
           )
       }}
    end
  end

  @spec init(String.t(), keyword()) :: {:ok, state()} | {:error, term()}
  def init(run_id, opts) do
    with {:ok, state} <- init_store(opts),
         {:ok, state} <- ensure_initialized(run_id, state) do
      {:ok, state}
    end
  end

  @spec db_path(String.t(), state() | keyword()) :: String.t()
  def db_path(run_id, %{data_dir: data_dir, org_id: org_id, project_id: project_id}) do
    Paths.db_path(data_dir, run_id, org_id, project_id)
  end

  def db_path(run_id, opts) when is_list(opts) do
    {:ok, state} = init_store(opts)
    db_path(run_id, state)
  end

  @impl Runic.Runner.Store
  def save(run_id, log, store_state) do
    with {:ok, state} <- ensure_initialized(run_id, store_state),
         {:ok, _checkpoint_seq} <- confirm_fence(run_id, state),
         :ok <- persist_checkpoint(state, log) do
      :ok
    else
      {:error, :stale_owner} ->
        raise StaleOwnerError, run_id: run_id, fence_token: store_state.fence_token

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Runic.Runner.Store
  def load(run_id, store_state) do
    case open_existing_db(run_id, store_state, fn _state, db ->
           with :ok <- SqliteMigrations.migrate(db),
                {:ok, log} <- load_workflow_log(db) do
             {:ok, log}
           end
         end) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Runic.Runner.Store
  def save_fact(hash, value, store_state) do
    with {:ok, state} <-
           ensure_initialized(store_state.run_id || raise_missing_run_id(), store_state),
         :ok <- persist_fact(state, hash, value) do
      :ok
    end
  end

  @impl Runic.Runner.Store
  def load_fact(hash, store_state) do
    run_id = store_state.run_id || raise_missing_run_id()

    case open_existing_db(run_id, store_state, fn _state, db ->
           with :ok <- SqliteMigrations.migrate(db),
                {:ok, blob} <-
                  Sqlite.first_value(db, "SELECT value FROM facts WHERE hash = ?", [hash]) do
             {:ok, :erlang.binary_to_term(blob)}
           end
         end) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Runic.Runner.Store
  def checkpoint(run_id, log, store_state), do: save(run_id, log, store_state)

  @impl Runic.Runner.Store
  def exists?(run_id, store_state) do
    run_id
    |> db_path(store_state)
    |> File.exists?()
  end

  @impl Runic.Runner.Store
  def delete(run_id, store_state) do
    path = db_path(run_id, store_state)

    for file <- [path, "#{path}-wal", "#{path}-shm"] do
      if File.exists?(file) do
        File.rm(file)
      end
    end

    :ok
  end

  defp confirm_fence(run_id, %{repo: repo, fence_token: fence_token, lease_table: lease_table}) do
    sql = """
    UPDATE #{lease_table}
    SET checkpoint_seq = checkpoint_seq + 1
    WHERE run_id = $1 AND fence_token = $2
    RETURNING checkpoint_seq
    """

    repo.transaction(fn ->
      case Ecto.Adapters.SQL.query(repo, sql, [dump_uuid(run_id), fence_token]) do
        {:ok, %{rows: [[checkpoint_seq]]}} ->
          checkpoint_seq

        {:ok, %{num_rows: 0}} ->
          repo.rollback(:stale_owner)

        {:error, reason} ->
          repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, checkpoint_seq} -> {:ok, checkpoint_seq}
      {:error, :stale_owner} -> {:error, :stale_owner}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_checkpoint(state, log) do
    serialized_log = :erlang.term_to_binary(log, [:compressed])

    with_db(state, fn db ->
      result =
        Sqlite.transaction(db, fn ->
          with :ok <- upsert_fence(db, state.fence_token),
               :ok <- upsert_meta(db, state),
               :ok <- persist_facts_rows(db, facts_from_log(log)),
               :ok <- reset_workflow_log(db),
               :ok <- persist_snapshot(db, serialized_log) do
            :ok
          end
        end)

      with :ok <- result,
           :ok <- Sqlite.wal_checkpoint(db, :passive) do
        :ok
      end
    end)
  end

  defp load_workflow_log(db) do
    load_latest_snapshot(db)
  end

  defp load_latest_snapshot(db) do
    with {:ok, blob} <-
           Sqlite.first_value(
             db,
             "SELECT data FROM workflow_log ORDER BY id DESC LIMIT 1"
           ) do
      {:ok, :erlang.binary_to_term(blob)}
    end
  end

  defp persist_snapshot(db, serialized_log) do
    case Sqlite.query(
           db,
           "INSERT INTO workflow_log (data, created_at) VALUES (?, ?)",
           [{:blob, serialized_log}, DateTime.utc_now() |> DateTime.to_iso8601()]
         ) do
      {:ok, _rows} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reset_workflow_log(db) do
    case Sqlite.query(db, "DELETE FROM workflow_log") do
      {:ok, _rows} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_fact(state, hash, value) do
    value_blob = :erlang.term_to_binary(value, [:compressed])

    with_db(state, fn db ->
      with :ok <- SqliteMigrations.migrate(db),
           :ok <- upsert_fence(db, state.fence_token),
           :ok <- upsert_meta(db, state),
           {:ok, _rows} <-
             Sqlite.query(
               db,
               """
               INSERT INTO facts (hash, value) VALUES (?, ?)
               ON CONFLICT(hash) DO UPDATE SET value = excluded.value
               """,
               [hash, {:blob, value_blob}]
             ),
           :ok <- Sqlite.wal_checkpoint(db, :passive) do
        :ok
      end
    end)
  end

  defp ensure_initialized(run_id, state) do
    state = %{state | run_id: run_id, db_path: db_path(run_id, state)}

    case with_db(state, fn db ->
           with :ok <- SqliteMigrations.migrate(db),
                :ok <- upsert_fence(db, state.fence_token),
                :ok <- upsert_meta(db, state) do
             :ok
           end
         end) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_existing_db(run_id, store_state, fun) when is_function(fun, 2) do
    path = db_path(run_id, store_state)

    if File.exists?(path) do
      state = %{store_state | run_id: run_id, db_path: path}

      with_db(state, fn db -> fun.(state, db) end)
    else
      {:error, :not_found}
    end
  end

  defp with_db(state, fun) do
    Sqlite.with_db(
      state.db_path || db_path(state.run_id, state),
      [create_dirs?: true],
      fun
    )
  end

  defp upsert_fence(db, fence_token) do
    case Sqlite.query(
           db,
           """
           INSERT INTO shard_fence (id, fence_token) VALUES (1, ?)
           ON CONFLICT(id) DO UPDATE SET fence_token = excluded.fence_token
           """,
           [fence_token]
         ) do
      {:ok, _rows} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_meta(db, state) do
    Enum.reduce_while(@meta_entries, :ok, fn key, :ok ->
      value =
        case key do
          :run_id -> state.run_id
          :org_id -> state.org_id
          :project_id -> state.project_id
        end

      case upsert_meta_entry(db, Atom.to_string(key), value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_meta_entry(db, key, value) do
    case Sqlite.query(
           db,
           """
           INSERT INTO meta (key, value) VALUES (?, ?)
           ON CONFLICT(key) DO UPDATE SET value = excluded.value
           """,
           [key, value]
         ) do
      {:ok, _rows} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_facts_rows(_db, facts) when map_size(facts) == 0, do: :ok

  defp persist_facts_rows(db, facts) do
    with {:ok, existing_hashes} <- existing_fact_hashes(db, Map.keys(facts)) do
      facts
      |> Enum.reject(fn {hash, _value} -> MapSet.member?(existing_hashes, hash) end)
      |> Enum.reduce_while(:ok, fn {hash, value}, :ok ->
        blob = :erlang.term_to_binary(value, [:compressed])

        case Sqlite.query(
               db,
               """
               INSERT INTO facts (hash, value) VALUES (?, ?)
               ON CONFLICT(hash) DO NOTHING
               """,
               [hash, {:blob, blob}]
             ) do
          {:ok, _rows} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp existing_fact_hashes(_db, []), do: {:ok, MapSet.new()}

  defp existing_fact_hashes(db, hashes) do
    hashes
    |> Enum.chunk_every(@fact_lookup_chunk_size)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn chunk, {:ok, acc} ->
      placeholders = chunk |> Enum.map(fn _hash -> "?" end) |> Enum.join(",")

      case Sqlite.query(db, "SELECT hash FROM facts WHERE hash IN (#{placeholders})", chunk) do
        {:ok, rows} ->
          found = rows |> Enum.map(&hd/1) |> MapSet.new()
          {:cont, {:ok, MapSet.union(acc, found)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp facts_from_log(log) do
    Enum.reduce(log, %{}, fn
      %FactProduced{hash: hash, value: value}, acc when not is_nil(hash) and not is_nil(value) ->
        Map.put(acc, hash, value)

      _event, acc ->
        acc
    end)
  end

  defp present_string(value, _key) when is_binary(value) and byte_size(value) > 0,
    do: {:ok, value}

  defp present_string(_, key), do: {:error, {:missing_option, key}}

  defp raise_missing_run_id do
    raise ArgumentError, "store_state.run_id is required for fact operations"
  end

  defp dump_uuid(run_id) when is_binary(run_id), do: Ecto.UUID.dump!(run_id)
  defp dump_uuid(run_id), do: run_id
end
