defmodule Fizz.Workflows.Store.SqliteMigrations do
  @moduledoc false

  alias Fizz.Workflows.Store.Sqlite

  @current_version 1

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @spec migrate(Exqlite.Sqlite3.db()) :: :ok | {:error, term()}
  def migrate(db) do
    with {:ok, version} <- Sqlite.first_value(db, "PRAGMA user_version") do
      cond do
        version > @current_version ->
          {:error, {:unsupported_user_version, version}}

        version == @current_version ->
          :ok

        true ->
          run_migrations(db, version + 1)
      end
    end
  end

  defp run_migrations(_db, version) when version > @current_version, do: :ok

  defp run_migrations(db, version) do
    with :ok <- migrate_to(db, version) do
      run_migrations(db, version + 1)
    end
  end

  defp migrate_to(db, 1) do
    Sqlite.transaction(db, fn ->
      with :ok <- Sqlite.execute(db, workflow_log_sql()),
           :ok <- Sqlite.execute(db, shard_fence_sql()),
           :ok <- Sqlite.execute(db, facts_sql()),
           :ok <- Sqlite.execute(db, meta_sql()),
           :ok <- Sqlite.execute(db, "PRAGMA user_version = 1") do
        :ok
      end
    end)
  end

  defp workflow_log_sql do
    """
    CREATE TABLE IF NOT EXISTS workflow_log (
      id INTEGER PRIMARY KEY,
      data BLOB NOT NULL,
      created_at TEXT NOT NULL
    )
    """
  end

  defp shard_fence_sql do
    """
    CREATE TABLE IF NOT EXISTS shard_fence (
      id INTEGER PRIMARY KEY,
      fence_token BIGINT NOT NULL
    )
    """
  end

  defp facts_sql do
    """
    CREATE TABLE IF NOT EXISTS facts (
      hash TEXT PRIMARY KEY,
      value BLOB NOT NULL
    )
    """
  end

  defp meta_sql do
    """
    CREATE TABLE IF NOT EXISTS meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
    """
  end
end
