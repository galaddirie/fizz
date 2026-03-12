defmodule Fizz.Runtime.Expression.Cache do
  @moduledoc """
  ETS-based cache for compiled Liquid templates.

  Caches the result of `Solid.parse/1` to avoid repeated parsing
  of the same template strings. Uses template content hash as key.

  ## Configuration

  Configure via application env:

      config :fizz, Fizz.Runtime.Expression.Cache,
        max_entries: 10_000,
        ttl_seconds: 3600

  ## Usage

  The cache is automatically used by `Fizz.Runtime.Expression.evaluate/3`.
  Direct usage:

      {:ok, compiled} = Cache.get_or_compile("Hello {{ name }}")

  ## Cleanup

  Old entries are periodically cleaned up. You can also manually clear:

      Cache.clear()
      Cache.stats()  # Get cache statistics
  """

  use GenServer

  require Logger

  @ets_table :fizz_expression_cache
  @default_max_entries 10_000
  @default_ttl_seconds 3600
  @cleanup_interval_ms 60_000

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a compiled template from cache or compiles and caches it.

  Returns `{:ok, compiled}` or `{:error, reason}`.
  """
  @spec get_or_compile(String.t()) :: {:ok, Solid.Template.t()} | {:error, term()}
  def get_or_compile(template) when is_binary(template) do
    key = hash_template(template)

    case lookup(key) do
      {:ok, compiled} ->
        touch(key)
        {:ok, compiled}

      :miss ->
        compile_and_cache(template, key)
    end
  end

  @doc """
  Clears all cached templates.
  """
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@ets_table)
    :ok
  end

  @doc """
  Returns cache statistics.
  """
  @spec stats() :: %{entries: non_neg_integer(), memory_bytes: non_neg_integer()}
  def stats do
    info = :ets.info(@ets_table)

    %{
      entries: Keyword.get(info, :size, 0),
      memory_bytes: Keyword.get(info, :memory, 0) * :erlang.system_info(:wordsize)
    }
  end

  @doc """
  Removes a specific template from cache.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(template) when is_binary(template) do
    key = hash_template(template)
    :ets.delete(@ets_table, key)
    :ok
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS table
    :ets.new(@ets_table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %{hits: 0, misses: 0}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_entries()
    enforce_max_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, Map.merge(stats(), state), state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp lookup(key) do
    case :ets.lookup(@ets_table, key) do
      [{^key, compiled, _timestamp}] -> {:ok, compiled}
      [] -> :miss
    end
  end

  defp touch(key) do
    now = System.monotonic_time(:second)
    :ets.update_element(@ets_table, key, {3, now})
  rescue
    ArgumentError -> :ok
  end

  defp compile_and_cache(template, key) do
    case Solid.parse(template) do
      {:ok, compiled} ->
        now = System.monotonic_time(:second)
        :ets.insert(@ets_table, {key, compiled, now})
        {:ok, compiled}

      {:error, error} ->
        {:error, error}
    end
  end

  defp hash_template(template) do
    :crypto.hash(:md5, template)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_old_entries do
    ttl = config(:ttl_seconds, @default_ttl_seconds)
    cutoff = System.monotonic_time(:second) - ttl

    # Delete entries older than TTL
    :ets.select_delete(@ets_table, [
      {{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
    ])
  end

  defp enforce_max_entries do
    max = config(:max_entries, @default_max_entries)
    current = :ets.info(@ets_table, :size)

    if current > max do
      # Remove oldest 10% of entries
      to_remove = div(max, 10)

      @ets_table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_key, _compiled, timestamp} -> timestamp end)
      |> Enum.take(to_remove)
      |> Enum.each(fn {key, _, _} -> :ets.delete(@ets_table, key) end)
    end
  end

  defp config(key, default) do
    Application.get_env(:fizz, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
