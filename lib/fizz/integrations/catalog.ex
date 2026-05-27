defmodule Fizz.Integrations.Catalog do
  @moduledoc """
  Supervised read-only catalog for integration metadata.
  """

  use GenServer

  @table :fizz_integration_catalog
  @kinds [:provider, :integration, :trigger, :resolver]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec providers() :: [map() | struct()]
  def providers, do: list(:provider)

  @spec provider(String.t()) :: {:ok, map() | struct()} | {:error, :not_found}
  def provider(id), do: get(:provider, id)

  @spec integrations() :: [map() | struct()]
  def integrations, do: list(:integration)

  @spec integration(String.t()) :: {:ok, map() | struct()} | {:error, :not_found}
  def integration(id), do: get(:integration, id)

  @spec triggers() :: [map()]
  def triggers, do: list(:trigger)

  @spec trigger(String.t()) :: {:ok, map()} | {:error, :not_found}
  def trigger(id), do: get(:trigger, id)

  @spec resolvers() :: [map()]
  def resolvers, do: list(:resolver)

  @spec resolver(String.t()) :: {:ok, map()} | {:error, :not_found}
  def resolver(id), do: get(:resolver, id)

  @impl true
  def init(opts) do
    create_table()

    manifest = Keyword.get(opts, :manifest, Fizz.Integrations.Manifest)
    load_manifest!(manifest)

    {:ok, %{manifest: manifest}}
  end

  defp list(kind) when kind in @kinds do
    @table
    |> :ets.match_object({{kind, :_}, :_})
    |> Enum.map(fn {{_kind, _id}, value} -> value end)
    |> Enum.sort_by(&catalog_sort_key/1)
  end

  defp get(kind, id) when kind in @kinds and is_binary(id) do
    case :ets.lookup(@table, {kind, id}) do
      [{{^kind, ^id}, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  defp load_manifest!(manifest) do
    definitions = manifest.definitions()

    insert_all(:provider, definitions.providers, & &1.id)
    insert_all(:integration, definitions.integrations, & &1.id)
    insert_all(:trigger, definitions.triggers, & &1.id)
    insert_all(:resolver, definitions.resolvers, & &1.id)
  end

  defp insert_all(kind, entries, id_fun) do
    Enum.each(entries, fn entry ->
      id = id_fun.(entry)
      :ets.insert(@table, {{kind, id}, entry})
    end)
  end

  defp catalog_sort_key(%{id: id}), do: id
  defp catalog_sort_key(%{display_name: display_name}), do: display_name
  defp catalog_sort_key(%{label: label}), do: label
  defp catalog_sort_key(entry), do: inspect(entry)

  defp create_table do
    case :ets.whereis(@table) do
      :undefined -> :ok
      tid -> :ets.delete(tid)
    end

    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
  end
end
