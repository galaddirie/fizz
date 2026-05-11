defmodule Fizz.Integrations.Registry do
  @moduledoc """
  ETS-backed registry for product-level integration modules.

  This mirrors the step registry approach: integrations are code-defined and
  loaded at application boot, with optional release-time configuration for
  additional modules.
  """

  use GenServer

  @table :fizz_integrations

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec all() :: [map()]
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, entry} -> entry end)
    |> Enum.sort_by(& &1.display_name)
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def init(opts) do
    create_table()

    opts
    |> integration_modules()
    |> Enum.map(&entry!/1)
    |> Enum.each(&:ets.insert(@table, {&1.id, &1}))

    {:ok, %{}}
  end

  defp integration_modules(opts) do
    configured = Keyword.get(opts, :modules) || Application.get_env(:fizz, :integrations)

    case configured do
      modules when is_list(modules) -> modules
      _ -> builtin_modules()
    end
  end

  defp builtin_modules do
    [
      Fizz.Integrations.Google.Sheets
    ]
  end

  defp entry!(module) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- implements_integration?(module) do
      %{
        id: module.id(),
        display_name: module.display_name(),
        provider_id: module.provider_id(),
        module: module,
        actions: module.actions(),
        triggers: module.triggers()
      }
    else
      _ -> raise ArgumentError, "#{inspect(module)} must implement Fizz.Integrations.Integration"
    end
  end

  defp implements_integration?(module) do
    Enum.all?(
      [:id, :display_name, :provider_id, :actions, :triggers, :required_scopes],
      &function_exported?(module, &1, callback_arity(&1))
    )
  end

  defp callback_arity(:required_scopes), do: 1
  defp callback_arity(_callback), do: 0

  defp create_table do
    case :ets.whereis(@table) do
      :undefined -> :ok
      tid -> :ets.delete(tid)
    end

    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
  end
end
