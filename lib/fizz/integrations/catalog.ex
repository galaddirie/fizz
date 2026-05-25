defmodule Fizz.Integrations.Catalog do
  @moduledoc """
  Supervised read-only catalog for integration metadata.
  """

  use GenServer

  @table :fizz_integration_catalog
  @kinds [:provider, :credential, :integration, :operation, :trigger, :resolver, :version]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec providers() :: [map() | struct()]
  def providers, do: list(:provider)

  @spec provider(String.t()) :: {:ok, map() | struct()} | {:error, :not_found}
  def provider(id), do: get(:provider, id)

  @spec credentials() :: [map() | struct()]
  def credentials, do: list(:credential)

  @spec credential(String.t()) :: {:ok, map() | struct()} | {:error, :not_found}
  def credential(id), do: get(:credential, id)

  @spec integrations() :: [map() | struct()]
  def integrations, do: list(:integration)

  @spec integration(String.t()) :: {:ok, map() | struct()} | {:error, :not_found}
  def integration(id), do: get(:integration, id)

  @spec operations() :: [map() | struct()]
  def operations, do: list(:operation)

  @spec operation(String.t()) :: {:ok, map() | struct()} | {:error, :not_found}
  def operation(id), do: get(:operation, id)

  @spec operation_for_step_type(String.t()) ::
          {:ok, map() | struct()}
          | {:error, {:operation_not_found, String.t()}}
          | {:error, {:operation_version_required, String.t(), [pos_integer()]}}
  def operation_for_step_type(step_type_id) when is_binary(step_type_id) do
    case operations_for_step_type(step_type_id) do
      [] ->
        {:error, {:operation_not_found, step_type_id}}

      [operation] ->
        {:ok, operation}

      operations ->
        versions = operations |> Enum.map(& &1.version) |> Enum.sort()
        {:error, {:operation_version_required, step_type_id, versions}}
    end
  end

  @spec operation_for_step_type(String.t(), pos_integer()) ::
          {:ok, map() | struct()} | {:error, {:operation_not_found, String.t(), pos_integer()}}
  def operation_for_step_type(step_type_id, version)
      when is_binary(step_type_id) and is_integer(version) do
    case :ets.lookup(@table, {:operation_step_version, step_type_id, version}) do
      [{{:operation_step_version, ^step_type_id, ^version}, operation_id}] ->
        operation(operation_id)

      [] ->
        {:error, {:operation_not_found, step_type_id, version}}
    end
  end

  @spec triggers() :: [map()]
  def triggers, do: list(:trigger)

  @spec trigger(String.t()) :: {:ok, map()} | {:error, :not_found}
  def trigger(id), do: get(:trigger, id)

  @spec resolvers() :: [map()]
  def resolvers, do: list(:resolver)

  @spec resolver(String.t()) :: {:ok, map()} | {:error, :not_found}
  def resolver(id), do: get(:resolver, id)

  @spec versions() :: [map()]
  def versions, do: list(:version)

  @spec version(String.t()) :: {:ok, map()} | {:error, :not_found}
  def version(id), do: get(:version, id)

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

  defp operations_for_step_type(step_type_id) do
    operations()
    |> Enum.filter(&(&1.step_type_id == step_type_id))
    |> Enum.sort_by(& &1.version)
  end

  defp load_manifest!(manifest) do
    definitions = manifest.definitions()

    insert_all(:provider, definitions.providers, & &1.id)
    insert_all(:credential, definitions.credentials, & &1.id)
    insert_all(:integration, definitions.integrations, & &1.id)
    insert_all(:operation, definitions.operations, & &1.id)
    insert_all(:trigger, definitions.triggers, & &1.id)
    insert_all(:resolver, definitions.resolvers, & &1.id)

    version_entries =
      Enum.map(definitions.versions, fn {step_type_id, versions} ->
        %{id: step_type_id, versions: versions}
      end)

    insert_all(:version, version_entries, & &1.id)
  end

  defp insert_all(kind, entries, id_fun) do
    Enum.each(entries, fn entry ->
      id = id_fun.(entry)
      :ets.insert(@table, {{kind, id}, entry})
      maybe_insert_operation_indexes(kind, entry)
    end)
  end

  defp maybe_insert_operation_indexes(:operation, entry) do
    :ets.insert(@table, {{:operation_step_version, entry.step_type_id, entry.version}, entry.id})
  end

  defp maybe_insert_operation_indexes(_kind, _entry), do: :ok

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
