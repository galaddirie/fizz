defmodule Fizz.Workflows.Store.SqliteStoreTest do
  use Fizz.DataCase, async: false

  import Fizz.WorkflowsFixtures

  alias Fizz.Workflows.Store.Paths
  alias Fizz.Workflows.Store.Sqlite
  alias Fizz.Workflows.Store.SqliteMigrations
  alias Fizz.Workflows.Store.SqliteStore
  alias Fizz.Workflows.Store.StaleOwnerError
  alias Runic.Workflow.Events.FactProduced

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "fizz-sqlite-store-#{System.unique_integer([:positive])}")

    scope = project_scope_fixture()
    %{version: version} = published_version_fixture(scope)
    run = workflow_run_fixture(scope, version)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    opts = [
      data_dir: tmp_dir,
      org_id: scope.project.workos_organization_id,
      project_id: scope.project.id,
      fence_token: 1,
      repo: Repo
    ]

    %{tmp_dir: tmp_dir, run_id: run.id, opts: opts}
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

  test "save replaces the previous workflow log snapshot", %{run_id: run_id, opts: opts} do
    insert_lease(run_id, 1, "NOW() + interval '30 seconds'")
    assert {:ok, state} = SqliteStore.init(run_id, opts)

    first_log = [%{event: :started}, %{event: :middle}]
    second_log = first_log ++ [%{event: :completed}]

    assert :ok = SqliteStore.save(run_id, first_log, state)
    assert :ok = SqliteStore.save(run_id, second_log, state)
    assert :ok = SqliteStore.save(run_id, second_log, state)
    assert {:ok, ^second_log} = SqliteStore.load(run_id, state)

    assert :ok =
             Sqlite.with_db(state.db_path, fn db ->
               assert {:ok, rows} =
                        Sqlite.query(db, "SELECT data FROM workflow_log ORDER BY id ASC")

               assert [snapshot] = Enum.map(rows, fn [blob] -> :erlang.binary_to_term(blob) end)
               assert snapshot == second_log

               :ok
             end)

    assert %{checkpoint_seq: 3, fence_token: 1} = lease_row(run_id)
  end

  test "save does not duplicate fact rows across snapshots", %{run_id: run_id, opts: opts} do
    insert_lease(run_id, 1, "NOW() + interval '30 seconds'")
    assert {:ok, state} = SqliteStore.init(run_id, opts)

    first_fact = %FactProduced{hash: "fact-1", value: %{number: 1}}
    second_fact = %FactProduced{hash: "fact-2", value: %{number: 2}}

    assert :ok = SqliteStore.save(run_id, [first_fact], state)
    assert :ok = SqliteStore.save(run_id, [first_fact, second_fact], state)

    assert :ok =
             Sqlite.with_db(state.db_path, fn db ->
               assert {:ok, [[2]]} = Sqlite.query(db, "SELECT COUNT(*) FROM facts")
               :ok
             end)
  end

  test "legacy snapshot logs load and are replaced by the next snapshot", %{
    run_id: run_id,
    opts: opts
  } do
    insert_lease(run_id, 1, "NOW() + interval '30 seconds'")
    assert {:ok, state} = SqliteStore.init(run_id, opts)

    legacy_log = [%{event: :legacy}]

    assert :ok =
             Sqlite.with_db(state.db_path, fn db ->
               assert {:ok, _rows} =
                        Sqlite.query(
                          db,
                          "INSERT INTO workflow_log (data, created_at) VALUES (?, ?)",
                          [
                            {:blob, :erlang.term_to_binary(legacy_log, [:compressed])},
                            DateTime.utc_now() |> DateTime.to_iso8601()
                          ]
                        )

               :ok
             end)

    assert {:ok, ^legacy_log} = SqliteStore.load(run_id, state)

    migrated_log = legacy_log ++ [%{event: :after_legacy}]
    assert :ok = SqliteStore.save(run_id, migrated_log, state)

    assert :ok =
             Sqlite.with_db(state.db_path, fn db ->
               assert {:ok, rows} =
                        Sqlite.query(db, "SELECT data FROM workflow_log ORDER BY id ASC")

               assert [snapshot] = Enum.map(rows, fn [blob] -> :erlang.binary_to_term(blob) end)
               assert snapshot == migrated_log
               :ok
             end)
  end

  test "save with a stale fence token raises StaleOwnerError", %{run_id: run_id, opts: opts} do
    insert_lease(run_id, 2, "NOW() + interval '30 seconds'")
    assert {:ok, state} = SqliteStore.init(run_id, opts)

    assert_raise StaleOwnerError, fn ->
      SqliteStore.save(run_id, [%{event: :stale}], state)
    end
  end

  test "save with an expired lease raises StaleOwnerError", %{run_id: run_id, opts: opts} do
    insert_lease(run_id, 1, "NOW() - interval '1 second'")
    assert {:ok, state} = SqliteStore.init(run_id, opts)

    assert_raise StaleOwnerError, fn ->
      SqliteStore.save(run_id, [%{event: :expired}], state)
    end

    assert :ok =
             Sqlite.with_db(state.db_path, fn db ->
               assert {:ok, []} = Sqlite.query(db, "SELECT data FROM workflow_log")
               :ok
             end)
  end

  test "save_fact and load_fact round-trip individual facts", %{run_id: run_id, opts: opts} do
    insert_lease(run_id, 1, "NOW() + interval '30 seconds'")
    assert {:ok, state} = SqliteStore.init(run_id, opts)

    fact = %{payload: [1, 2, 3], nested: %{ok: true}}

    assert :ok = SqliteStore.save_fact("hash-123", fact, state)
    assert {:ok, ^fact} = SqliteStore.load_fact("hash-123", state)

    assert %{checkpoint_seq: 1, fence_token: 1} = lease_row(run_id)
  end

  test "save_fact with a stale fence token raises StaleOwnerError and preserves facts", %{
    run_id: run_id,
    opts: opts
  } do
    insert_lease(run_id, 1, "NOW() + interval '30 seconds'")
    assert {:ok, state} = SqliteStore.init(run_id, opts)

    original_fact = %{payload: "current"}
    assert :ok = SqliteStore.save_fact("hash-stale", original_fact, state)

    update_lease(run_id, 2, "NOW() + interval '30 seconds'")

    assert_raise StaleOwnerError, fn ->
      SqliteStore.save_fact("hash-stale", %{payload: "stale"}, state)
    end

    assert {:ok, ^original_fact} = SqliteStore.load_fact("hash-stale", state)
    assert %{checkpoint_seq: 1, fence_token: 2} = lease_row(run_id)
  end

  test "save_fact with an expired lease raises StaleOwnerError", %{run_id: run_id, opts: opts} do
    insert_lease(run_id, 1, "NOW() - interval '1 second'")
    assert {:ok, state} = SqliteStore.init(run_id, opts)

    assert_raise StaleOwnerError, fn ->
      SqliteStore.save_fact("hash-expired", %{payload: "expired"}, state)
    end

    assert :ok =
             Sqlite.with_db(state.db_path, fn db ->
               assert {:ok, []} = Sqlite.query(db, "SELECT hash FROM facts")
               :ok
             end)
  end

  test "save_fact preserves existing content on fact hash conflict", %{
    run_id: run_id,
    opts: opts
  } do
    insert_lease(run_id, 1, "NOW() + interval '30 seconds'")
    assert {:ok, state} = SqliteStore.init(run_id, opts)

    original_fact = %{version: 1}
    conflicting_fact = %{version: 2}

    assert :ok = SqliteStore.save_fact("hash-conflict", original_fact, state)
    assert :ok = SqliteStore.save_fact("hash-conflict", original_fact, state)

    assert {:error, :fact_hash_conflict} =
             SqliteStore.save_fact("hash-conflict", conflicting_fact, state)

    assert {:ok, ^original_fact} = SqliteStore.load_fact("hash-conflict", state)
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

  defp update_lease(run_id, fence_token, lease_expiry_sql) do
    sql = """
    UPDATE workflow_run_leases
    SET fence_token = $2, lease_expiry = #{lease_expiry_sql}
    WHERE run_id = $1
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
