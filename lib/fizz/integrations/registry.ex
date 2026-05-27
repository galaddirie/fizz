defmodule Fizz.Integrations.Registry do
  @moduledoc """
  ETS-backed registry for product-level integration modules.

  This mirrors the step registry approach: integrations are code-defined and
  loaded at application boot, with optional release-time configuration for
  additional modules.
  """

  use GenServer

  @table :fizz_integrations
  @replacement_config_key :replace_integrations_for_test

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
    |> entries_for_modules!()
    |> validate_entries!()
    |> Enum.each(&:ets.insert(@table, {&1.id, &1}))

    {:ok, %{}}
  end

  @doc false
  @spec modules_for_load(keyword()) :: [module()]
  def modules_for_load(opts \\ []) when is_list(opts) do
    integration_modules(opts)
  end

  @doc false
  @spec entries_for_modules!([module()]) :: [map()]
  def entries_for_modules!(modules) when is_list(modules) do
    Enum.map(modules, &entry!/1)
  end

  def entries_for_modules!(modules) do
    raise ArgumentError, "integration modules must be a list, got: #{inspect(modules)}"
  end

  @doc false
  @spec validate_entries!([map()]) :: [map()]
  def validate_entries!(entries) when is_list(entries) do
    entries
    |> validate_unique_ids!()
    |> Enum.each(&validate_entry!/1)

    entries
  end

  def validate_entries!(_entries) do
    raise ArgumentError, "integration entries must be a list"
  end

  defp integration_modules(opts) do
    configured = Keyword.get(opts, :modules) || Application.get_env(:fizz, :integrations, [])

    case configured do
      modules when is_list(modules) ->
        if replace_integrations?(opts), do: modules, else: builtin_modules() ++ modules

      nil ->
        builtin_modules()

      other ->
        raise ArgumentError, ":integrations must be a list, got: #{inspect(other)}"
    end
  end

  defp replace_integrations?(opts) do
    Keyword.get(opts, :replace_modules, false) == true ||
      Application.get_env(:fizz, @replacement_config_key, false) == true
  end

  defp builtin_modules do
    Fizz.Integrations.Manifest.integration_modules()
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
        triggers: module.triggers(),
        step_modules: module.step_modules()
      }
    else
      _ -> raise ArgumentError, "#{inspect(module)} must implement Fizz.Integrations.Integration"
    end
  end

  defp implements_integration?(module) do
    Enum.all?(
      [:id, :display_name, :provider_id, :actions, :triggers, :step_modules, :required_scopes],
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

  defp validate_unique_ids!(entries) do
    duplicate_ids =
      entries
      |> Enum.map(& &1.id)
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(fn {id, _count} -> id end)
      |> Enum.sort()

    case duplicate_ids do
      [] -> entries
      ids -> raise ArgumentError, "duplicate integration IDs: #{inspect(ids)}"
    end
  end

  defp validate_entry!(entry) do
    validate_required_fields!(entry)
    validate_provider!(entry)
    validate_action_step_ids!(entry.actions, entry.id)
    validate_trigger_modules!(entry.triggers, Fizz.Triggers.Source, :trigger, entry.id)
    validate_step_modules!(entry.step_modules, entry)
  end

  defp validate_required_fields!(%{
         id: id,
         display_name: display_name,
         provider_id: provider_id,
         module: module,
         actions: actions,
         triggers: triggers,
         step_modules: step_modules
       })
       when is_binary(id) and id != "" and is_binary(display_name) and display_name != "" and
              (is_nil(provider_id) or (is_binary(provider_id) and provider_id != "")) and
              is_atom(module) and is_list(actions) and is_list(triggers) and
              is_list(step_modules),
       do: :ok

  defp validate_required_fields!(entry) do
    raise ArgumentError, "invalid integration entry: #{inspect(entry)}"
  end

  defp validate_provider!(%{provider_id: nil}), do: :ok

  defp validate_provider!(%{id: id, provider_id: provider_id}) do
    case Fizz.Integrations.ProviderCatalog.provider(provider_id) do
      {:ok, _provider} ->
        :ok

      {:error, :unknown_provider} ->
        raise ArgumentError, "integration #{id} uses unknown provider #{provider_id}"
    end
  end

  defp validate_step_modules!(modules, entry) do
    Enum.each(modules, fn module ->
      validate_step_module!(module, entry)
    end)
  end

  defp validate_step_module!(module, entry) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        validate_step_definition!(module, entry)

      _ ->
        raise ArgumentError,
              "integration #{entry.id} step module #{inspect(module)} is not loaded"
    end
  end

  defp validate_step_module!(module, entry) do
    raise ArgumentError, "integration #{entry.id} step module is invalid: #{inspect(module)}"
  end

  defp validate_step_definition!(module, entry) do
    if function_exported?(module, :__step_definition__, 0) do
      module
      |> apply(:__step_definition__, [])
      |> validate_step_ownership!(module, entry)
    else
      raise ArgumentError,
            "integration #{entry.id} step module #{inspect(module)} must use Fizz.Integrations.StepDefinition"
    end
  end

  defp validate_step_ownership!(step_type, module, entry) do
    cond do
      step_type.integration != entry.id ->
        raise ArgumentError,
              "integration #{entry.id} step module #{inspect(module)} declares integration #{inspect(step_type.integration)}"

      step_type.provider != entry.provider_id ->
        raise ArgumentError,
              "integration #{entry.id} step module #{inspect(module)} declares provider #{inspect(step_type.provider)}"

      true ->
        :ok
    end
  end

  defp validate_action_step_ids!(actions, integration_id) do
    Enum.each(actions, fn
      action when is_binary(action) and action != "" ->
        :ok

      action ->
        raise ArgumentError,
              "integration #{integration_id} action step type ID is invalid: #{inspect(action)}"
    end)
  end

  defp validate_trigger_modules!(modules, behaviour, kind, integration_id) do
    Enum.each(modules, fn module ->
      validate_trigger_module!(module, behaviour, kind, integration_id)
    end)
  end

  defp validate_trigger_module!(module, behaviour, kind, integration_id) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        validate_trigger_behaviour!(module, behaviour, kind, integration_id)

      _ ->
        raise ArgumentError,
              "integration #{integration_id} #{kind} module #{inspect(module)} is not loaded"
    end
  end

  defp validate_trigger_module!(module, _behaviour, kind, integration_id) do
    raise ArgumentError,
          "integration #{integration_id} #{kind} module is invalid: #{inspect(module)}"
  end

  defp validate_trigger_behaviour!(module, behaviour, kind, integration_id) do
    behaviours =
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    case behaviour in behaviours do
      true ->
        :ok

      false ->
        raise ArgumentError,
              "integration #{integration_id} #{kind} module #{inspect(module)} must implement #{inspect(behaviour)}"
    end
  end
end
