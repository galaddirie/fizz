defmodule Fizz.Workflows.Store.SqliteStoreTest do
  use Fizz.DataCase, async: false

  alias Fizz.Workflows.Store.Paths
  alias Fizz.Workflows.Store.Sqlite
  alias Fizz.Workflows.Store.SqliteMigrations
  alias Fizz.Workflows.Store.SqliteStore
  alias Fizz.Workflows.Store.StaleOwnerError

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "fizz-sqlite-store-#{System.unique_integer([:positive])}")

    run_id = Ecto.UUID.generate()

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    opts = [
      data_dir: tmp_dir,
      org_id: "org_test",
      project_id: Ecto.UUID.generate(),
      fence_token: 1,
      repo: Repo
    ]

    %{tmp_dir: tmp_dir, run_id: run_id, opts: opts}
  end

  test "init creates sqlite file with expected schema and WAL mode", %{
    run_id: run_id,
    opts: opts
  } do
    assert {:ok, state} = SqliteStore.init(run_id, opts)
    assert File.exists?(state.db_path)
    current_version = SqliteMigrations.current_version()

    assert :ok =
             Sqlite.with_db(state.db_path, fn db ->
               assert {:ok, "wal"} = Sqlite.first_value(db, "PRAGMA journal_mode")
               assert {:ok, 1} = Sqlite.first_value(db, "PRAGMA foreign_keys")
               assert {:ok, ^current_version} = Sqlite.first_value(db, "PRAGMA user_version")

               assert {:ok, rows} =
                        Sqlite.query(
                          db,
                          """
                          SELECT name
                          FROM sqlite_master
                          WHERE type = 'table'
                            AND name IN ('workflow_log', 'shard_fence', 'facts', 'meta')
                          ORDER BY name
                          """
                        )

               assert Enum.map(rows, &hd/1) == ["facts", "meta", "shard_fence", "workflow_log"]
               :ok
             end)
  end

  test "save and load round-trip the workflow log", %{run_id: run_id, opts: opts} do
    insert_lease(run_id, 1, "NOW() + interval '30 seconds'")
    assert {:ok, state} = SqliteStore.init(run_id, opts)

    log = [%{event: :started}, %{event: :completed, output: %{ok: true}}]

    assert :ok = SqliteStore.save(run_id, log, state)
    assert {:ok, ^log} = SqliteStore.load(run_id, state)

    assert %{checkpoint_seq: 1, fence_token: 1} = lease_row(run_id)
  end

  test "save with a stale fence token raises StaleOwnerError", %{run_id: run_id, opts: opts} do
    insert_lease(run_id, 2, "NOW() + interval '30 seconds'")
    assert {:ok, state} = SqliteStore.init(run_id, opts)

    assert_raise StaleOwnerError, fn ->
      SqliteStore.save(run_id, [%{event: :stale}], state)
    end
  end

  test "save_fact and load_fact round-trip individual facts", %{run_id: run_id, opts: opts} do
    assert {:ok, state} = SqliteStore.init(run_id, opts)

    fact = %{payload: [1, 2, 3], nested: %{ok: true}}

    assert :ok = SqliteStore.save_fact("hash-123", fact, state)
    assert {:ok, ^fact} = SqliteStore.load_fact("hash-123", state)
  end

  test "schema migration upgrades an older user_version", %{run_id: run_id, opts: opts} do
    path = SqliteStore.db_path(run_id, opts)
    current_version = SqliteMigrations.current_version()

    assert :ok =
             Sqlite.with_db(path, [create_dirs?: true, configure?: false], fn db ->
               Sqlite.execute(db, "PRAGMA user_version = 0")
             end)

    assert {:ok, state} = SqliteStore.init(run_id, opts)

    assert :ok =
             Sqlite.with_db(state.db_path, fn db ->
               assert {:ok, ^current_version} = Sqlite.first_value(db, "PRAGMA user_version")
               :ok
             end)
  end

  test "file is created in the hashed directory structure for Litestream discovery", %{
    tmp_dir: tmp_dir,
    run_id: run_id,
    opts: opts
  } do
    assert {:ok, state} = SqliteStore.init(run_id, opts)

    expected_relative = Paths.relative_db_path(run_id, opts[:org_id], opts[:project_id])

    assert Path.relative_to(state.db_path, Path.expand(tmp_dir)) == expected_relative
  end

  defp insert_lease(run_id, fence_token, lease_expiry_sql) do
    sql = """
    INSERT INTO workflow_run_leases (run_id, owner_node, fence_token, checkpoint_seq, lease_expiry)
    VALUES ($1, NULL, $2, 0, #{lease_expiry_sql})
    """

    assert {:ok, _result} = Ecto.Adapters.SQL.query(Repo, sql, [dump_uuid(run_id), fence_token])
  end

  defp lease_row(run_id) do
    assert {:ok, %{rows: [[owner_node, fence_token, checkpoint_seq]]}} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               SELECT owner_node, fence_token, checkpoint_seq
               FROM workflow_run_leases
               WHERE run_id = $1
               """,
               [dump_uuid(run_id)]
             )

    %{owner_node: owner_node, fence_token: fence_token, checkpoint_seq: checkpoint_seq}
  end

  defp dump_uuid(run_id), do: Ecto.UUID.dump!(run_id)
end
