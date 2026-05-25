defmodule Fizz.Workflows.Store.Sqlite do
  @moduledoc false

  alias Exqlite.Sqlite3

  @type db :: Exqlite.Sqlite3.db()
  @default_wal_autocheckpoint_pages 1_000
  @default_journal_size_limit_bytes 16 * 1_024 * 1_024

  @spec with_db(String.t(), keyword(), (db() -> result)) :: result | {:error, term()}
        when result: var
  def with_db(path, opts \\ [], fun) when is_function(fun, 1) do
    if Keyword.get(opts, :create_dirs?, false) do
      path |> Path.dirname() |> File.mkdir_p!()
    end

    case Sqlite3.open(path) do
      {:ok, db} ->
        try do
          with :ok <- maybe_configure(db, opts) do
            fun.(db)
          end
        after
          Sqlite3.close(db)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec execute(db(), String.t()) :: :ok | {:error, term()}
  def execute(db, sql), do: Sqlite3.execute(db, sql)

  @spec query(db(), String.t(), list()) :: {:ok, [list()]} | {:error, term()}
  def query(db, sql, params \\ []) do
    with {:ok, statement} <- Sqlite3.prepare(db, sql) do
      try do
        :ok = Sqlite3.bind(statement, params)
        Sqlite3.fetch_all(db, statement)
      after
        Sqlite3.release(db, statement)
      end
    end
  end

  @spec first_value(db(), String.t(), list()) :: {:ok, term()} | {:error, :not_found | term()}
  def first_value(db, sql, params \\ []) do
    case query(db, sql, params) do
      {:ok, [[value | _] | _]} -> {:ok, value}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec transaction(db(), (-> result), keyword()) :: result | {:error, term()} when result: var
  def transaction(db, fun, opts \\ []) when is_function(fun, 0) do
    begin_sql =
      case Keyword.get(opts, :mode, :immediate) do
        :exclusive -> "BEGIN EXCLUSIVE TRANSACTION"
        :deferred -> "BEGIN TRANSACTION"
        _ -> "BEGIN IMMEDIATE TRANSACTION"
      end

    with :ok <- execute(db, begin_sql) do
      try do
        case fun.() do
          :ok ->
            with :ok <- execute(db, "COMMIT") do
              :ok
            end

          {:ok, _value} = ok ->
            with :ok <- execute(db, "COMMIT") do
              ok
            end

          {:error, reason} ->
            rollback(db)
            {:error, reason}

          other ->
            with :ok <- execute(db, "COMMIT") do
              other
            end
        end
      rescue
        exception ->
          rollback(db)
          reraise(exception, __STACKTRACE__)
      catch
        kind, reason ->
          rollback(db)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp maybe_configure(db, opts) do
    if Keyword.get(opts, :configure?, true) do
      configure(db)
    else
      :ok
    end
  end

  @spec configure(db()) :: :ok | {:error, term()}
  def configure(db) do
    with {:ok, _} <- query(db, "PRAGMA journal_mode = WAL"),
         :ok <- execute(db, "PRAGMA synchronous = NORMAL"),
         :ok <- execute(db, "PRAGMA foreign_keys = ON"),
         :ok <-
           execute(db, "PRAGMA wal_autocheckpoint = #{@default_wal_autocheckpoint_pages}"),
         :ok <- execute(db, "PRAGMA journal_size_limit = #{@default_journal_size_limit_bytes}") do
      :ok
    end
  end

  @spec wal_checkpoint(db(), :passive | :truncate) :: :ok | {:error, term()}
  def wal_checkpoint(db, mode \\ :passive) do
    pragma =
      case mode do
        :truncate -> "PRAGMA wal_checkpoint(TRUNCATE)"
        :passive -> "PRAGMA wal_checkpoint(PASSIVE)"
      end

    case query(db, pragma) do
      {:ok, _rows} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback(db) do
    _ = execute(db, "ROLLBACK")
    :ok
  end
end
