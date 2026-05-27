defmodule Fizz.Integrations.StepRegistry do
  @moduledoc """
  In-memory registry for integration-owned step types.

  Step types are defined as code (not in DB) and loaded from integration
  `step_modules/0` declarations at startup. This provides:
  - Type-safe definitions with compile-time validation
  - Easy versioning through git
  - Fast lookups via ETS

  ## Usage

      # Get all step types
      Fizz.Integrations.StepRegistry.all()

      # Get a specific step type
      {:ok, type} = Fizz.Integrations.StepRegistry.get("http_request")

      # List by category
      Fizz.Integrations.StepRegistry.list_by_category("Integrations")

      # List by kind
      Fizz.Integrations.StepRegistry.list_by_kind(:action)

  ## Adding New Step Types

  Create an executor module that uses `Fizz.Integrations.StepDefinition`:

      defmodule Fizz.Integrations.Fizz.Builtins.MyStep do
        use Fizz.Integrations.StepDefinition,
          id: "my_step",
          name: "My Step",
          category: "Custom",
          description: "Does something cool",
          icon: "hero-sparkles",
          kind: :action,
          integration: "fizz"

        @behaviour Fizz.Workflows.StepExecutor
        # ... implementation
      end

  Add the module to its owning integration's `step_modules/0` list and it will be
  registered on startup.
  """

  use GenServer

  alias Fizz.Fields
  alias Fizz.Workflows.RetryPolicy
  alias Fizz.Integrations.StepType

  require Logger

  @ets_table :fizz_step_types
  @supported_ui_components Fields.supported_components()

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a step type dynamically.
  """
  @spec register(StepType.t()) :: :ok
  def register(%StepType{} = type) do
    validate_step_types!([type])
    validate_type_not_registered!(type)

    case GenServer.call(__MODULE__, {:register, type}) do
      :ok ->
        :ok

      {:error, :already_registered} ->
        raise ArgumentError, "step type #{type.id} is already registered"
    end
  end

  @doc """
  Removes a previously registered step type.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(type_id) when is_binary(type_id) do
    GenServer.call(__MODULE__, {:unregister, type_id})
  end

  @doc """
  Returns all registered step types.
  """
  @spec all() :: [StepType.t()]
  def all do
    @ets_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, type} -> type end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Gets a step type by ID.
  """
  @spec get(String.t()) :: {:ok, StepType.t()} | {:error, :not_found}
  def get(type_id) when is_binary(type_id) do
    case :ets.lookup(@ets_table, type_id) do
      [{^type_id, type}] -> {:ok, type}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Gets a step type by ID or raises.
  """
  @spec get!(String.t()) :: StepType.t()
  def get!(type_id) do
    case get(type_id) do
      {:ok, type} -> type
      {:error, :not_found} -> raise "Step type not found: #{type_id}"
    end
  end

  @doc """
  Returns the default configuration for a step type ID.
  """
  @spec get_default_config(String.t()) :: map()
  def get_default_config(type_id) when is_binary(type_id) do
    with {:ok, %StepType{} = type} <- get(type_id),
         default_config when is_map(default_config) <- get_type_default_config(type) do
      default_config
    else
      _ -> %{}
    end
  end

  @doc """
  Checks if a step type exists.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(type_id) when is_binary(type_id) do
    :ets.member(@ets_table, type_id)
  end

  @doc """
  Lists step types by category.
  """
  @spec list_by_category(String.t()) :: [StepType.t()]
  def list_by_category(category) when is_binary(category) do
    all()
    |> Enum.filter(&(&1.category == category))
  end

  @doc """
  Lists step types by kind.
  """
  @spec list_by_kind(StepType.step_kind()) :: [StepType.t()]
  def list_by_kind(kind) when kind in [:action, :trigger, :control_flow, :transform] do
    all()
    |> Enum.filter(&(&1.step_kind == kind))
  end

  @doc """
  Returns all unique categories.
  """
  @spec categories() :: [String.t()]
  def categories do
    all()
    |> Enum.map(& &1.category)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Returns step types grouped by category.
  """
  @spec grouped_by_category() :: %{String.t() => [StepType.t()]}
  def grouped_by_category do
    all()
    |> Enum.group_by(& &1.category)
  end

  @doc """
  Returns the count of registered step types.
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@ets_table, :size)
  end

  @doc """
  Returns step types formatted for the node library UI.
  """
  @spec library_items() :: [map()]
  def library_items do
    all()
    |> Enum.map(&library_item_from_type/1)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS table for fast lookups
    :ets.new(@ets_table, [:named_table, :set, :protected, read_concurrency: true])

    # Load all built-in step types
    types = discover_step_types()

    for type <- types do
      :ets.insert(@ets_table, {type.id, type})
    end

    Logger.info("Step Registry initialized with #{length(types)} step types")

    {:ok, %{}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    # Clear and reload all types
    :ets.delete_all_objects(@ets_table)

    types = discover_step_types()

    for type <- types do
      :ets.insert(@ets_table, {type.id, type})
    end

    Logger.info("Step Registry reloaded with #{length(types)} step types")

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:register, %StepType{} = type}, _from, state) do
    case :ets.member(@ets_table, type.id) do
      true ->
        {:reply, {:error, :already_registered}, state}

      false ->
        :ets.insert(@ets_table, {type.id, type})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:unregister, type_id}, _from, state) do
    :ets.delete(@ets_table, type_id)
    {:reply, :ok, state}
  end

  # ============================================================================
  # Step Type Discovery
  # ============================================================================

  @doc false
  @spec types_for_modules!([module()]) :: [StepType.t()]
  def types_for_modules!(modules) when is_list(modules) do
    modules
    |> Enum.filter(&has_step_definition?/1)
    |> Enum.map(& &1.__step_definition__())
    |> validate_step_types!()
  end

  def types_for_modules!(modules) do
    raise ArgumentError, "step executor modules must be a list, got: #{inspect(modules)}"
  end

  defp discover_step_types do
    # Get all executor modules and load their definitions
    builtin_executor_modules()
    |> types_for_modules!()
    |> validate_step_types!()
  end

  defp library_item_from_type(%StepType{} = type) do
    %{
      type_id: type.id,
      name: type.name,
      description: type.description,
      icon: type.icon,
      category: type.category,
      step_kind: Atom.to_string(type.step_kind),
      node_role: Atom.to_string(type.node_role)
    }
  end

  @spec builtin_executor_modules() :: [module()]
  defp builtin_executor_modules do
    Fizz.Integrations.Manifest.step_executor_modules()
  end

  defp has_step_definition?(module) do
    # Ensure module is loaded
    Code.ensure_loaded(module)
    function_exported?(module, :__step_definition__, 0)
  end

  defp validate_step_types!(types) do
    types
    |> validate_unique_ids()
    |> validate_icons!()
    |> validate_fields!()
    |> validate_retry_policies!()
    |> validate_config_schemas!()
  end

  defp validate_unique_ids(types) do
    ids = Enum.map(types, & &1.id)
    unique_ids = Enum.uniq(ids)

    if length(ids) != length(unique_ids) do
      duplicates = ids -- unique_ids

      raise "Duplicate step type IDs found: #{inspect(duplicates)}"
    end

    types
  end

  defp validate_type_not_registered!(type) do
    case exists?(type.id) do
      true -> raise ArgumentError, "step type #{type.id} is already registered"
      false -> :ok
    end
  end

  defp validate_icons!(types) do
    Enum.each(types, fn type ->
      case type.icon do
        icon when is_binary(icon) and icon != "" ->
          :ok

        _ ->
          raise ArgumentError, "step type #{type.id} is missing icon"
      end
    end)

    types
  end

  defp validate_fields!(types) do
    Enum.each(types, fn type ->
      Fields.validate!(type.fields)
    end)

    types
  end

  defp validate_retry_policies!(types) do
    Enum.each(types, fn type ->
      RetryPolicy.validate!(type.retry)
    end)

    types
  end

  defp validate_config_schemas!(types) do
    Enum.each(types, fn type ->
      default_config = get_type_default_config(type)
      properties = Map.get(type.config_schema, "properties", %{})

      Enum.each(properties, fn {field, schema} ->
        validate_schema_property!(type, [field], schema, default_config)
      end)

      validate_schema_property_references!(type, properties)
    end)

    types
  end

  defp validate_schema_property!(type, path, schema, default_config) when is_map(schema) do
    validate_ui_component!(type, path, schema)
    validate_schema_property_extensions!(type, path, schema)
    validate_credential_field!(type, path, schema, default_config)

    schema
    |> Map.get("properties", %{})
    |> Enum.each(fn {field, nested_schema} ->
      validate_schema_property!(type, path ++ [field], nested_schema, default_config)
    end)
  end

  defp validate_schema_property!(_type, _path, _schema, _default_config), do: :ok

  defp validate_ui_component!(type, path, schema) do
    case get_in(schema, ["ui", "component"]) do
      nil ->
        :ok

      component when component in @supported_ui_components ->
        :ok

      component ->
        raise ArgumentError,
              "step type #{type.id} field #{Enum.join(path, ".")} uses unsupported ui.component #{inspect(component)}"
    end
  end

  defp validate_schema_property_extensions!(type, path, schema) do
    field = Enum.join(path, ".")

    validate_depends_on!(
      type,
      field,
      Map.get(schema, "depends_on") || get_in(schema, ["ui", "depends_on"])
    )

    validate_optional_map!(type, field, "display", Map.get(schema, "display"))

    validate_resource_locator!(
      type,
      field,
      "resource_locator",
      Map.get(schema, "resource_locator")
    )

    validate_resource_mapper!(type, field, "resource_mapper", Map.get(schema, "resource_mapper"))
    validate_optional_map!(type, field, "ui.display", get_in(schema, ["ui", "display"]))

    validate_optional_map!(
      type,
      field,
      "ui.resource_locator",
      get_in(schema, ["ui", "resource_locator"])
    )

    validate_resource_locator!(
      type,
      field,
      "ui.resource_locator",
      get_in(schema, ["ui", "resource_locator"])
    )

    validate_resource_mapper!(
      type,
      field,
      "ui.resource_mapper",
      get_in(schema, ["ui", "resource_mapper"])
    )
  end

  defp validate_depends_on!(_type, _field, nil), do: :ok

  defp validate_depends_on!(type, field, depends_on) when is_list(depends_on) do
    unless Enum.all?(depends_on, &is_binary/1) do
      raise ArgumentError,
            "step type #{type.id} field #{field} depends_on must contain only strings"
    end
  end

  defp validate_depends_on!(type, field, depends_on) do
    raise ArgumentError,
          "step type #{type.id} field #{field} depends_on must be a list, got: #{inspect(depends_on)}"
  end

  defp validate_optional_map!(_type, _field, _key, nil), do: :ok
  defp validate_optional_map!(_type, _field, _key, value) when is_map(value), do: :ok

  defp validate_optional_map!(type, field, key, value) do
    raise ArgumentError,
          "step type #{type.id} field #{field} #{key} must be a map, got: #{inspect(value)}"
  end

  defp validate_resource_locator!(_type, _field, _key, nil), do: :ok

  defp validate_resource_locator!(type, field, key, locator) when is_map(locator) do
    validate_required_string!(type, field, "#{key}.kind", Map.get(locator, "kind"))
    validate_optional_string!(type, field, "#{key}.value_key", Map.get(locator, "value_key"))
  end

  defp validate_resource_locator!(type, field, key, value) do
    raise ArgumentError,
          "step type #{type.id} field #{field} #{key} must be a map, got: #{inspect(value)}"
  end

  defp validate_resource_mapper!(_type, _field, _key, nil), do: :ok

  defp validate_resource_mapper!(type, field, key, mapper) when is_map(mapper) do
    validate_required_string!(type, field, "#{key}.kind", Map.get(mapper, "kind"))
    validate_string_value_map!(type, field, "#{key}.fields", Map.get(mapper, "fields"))
    validate_string_value_map!(type, field, "#{key}.labels", Map.get(mapper, "labels"))
    validate_resource_mapper_lookups!(type, field, key, Map.get(mapper, "lookups"))
    validate_resource_mapper_errors!(type, field, key, Map.get(mapper, "errors"))
  end

  defp validate_resource_mapper!(type, field, key, value) do
    raise ArgumentError,
          "step type #{type.id} field #{field} #{key} must be a map, got: #{inspect(value)}"
  end

  defp validate_resource_mapper_lookups!(_type, _field, _key, nil), do: :ok

  defp validate_resource_mapper_lookups!(type, field, key, lookups) when is_map(lookups) do
    Enum.each(lookups, fn {lookup_name, lookup} ->
      lookup_label = "#{key}.lookups.#{lookup_name}"

      case lookup do
        %{} ->
          validate_required_string!(type, field, "#{lookup_label}.mode", Map.get(lookup, "mode"))

          validate_string_value_map!(
            type,
            field,
            "#{lookup_label}.params",
            Map.get(lookup, "params")
          )

          validate_optional_string!(
            type,
            field,
            "#{lookup_label}.parent_option_field",
            Map.get(lookup, "parent_option_field")
          )

        _ ->
          raise ArgumentError,
                "step type #{type.id} field #{field} #{lookup_label} must be a map, got: #{inspect(lookup)}"
      end
    end)
  end

  defp validate_resource_mapper_lookups!(type, field, key, value) do
    raise ArgumentError,
          "step type #{type.id} field #{field} #{key}.lookups must be a map, got: #{inspect(value)}"
  end

  defp validate_resource_mapper_errors!(_type, _field, _key, nil), do: :ok

  defp validate_resource_mapper_errors!(type, field, key, errors) when is_map(errors) do
    Enum.each(errors, fn {scope, messages} ->
      case messages do
        %{} ->
          validate_string_value_map!(type, field, "#{key}.errors.#{scope}", messages)

        _ ->
          raise ArgumentError,
                "step type #{type.id} field #{field} #{key}.errors.#{scope} must be a map, got: #{inspect(messages)}"
      end
    end)
  end

  defp validate_resource_mapper_errors!(type, field, key, value) do
    raise ArgumentError,
          "step type #{type.id} field #{field} #{key}.errors must be a map, got: #{inspect(value)}"
  end

  defp validate_string_value_map!(_type, _field, _key, nil), do: :ok

  defp validate_string_value_map!(type, field, key, value) when is_map(value) do
    Enum.each(value, fn {entry_key, entry_value} ->
      validate_required_string!(type, field, "#{key}.#{entry_key}", entry_value)
    end)
  end

  defp validate_string_value_map!(type, field, key, value) do
    raise ArgumentError,
          "step type #{type.id} field #{field} #{key} must be a map, got: #{inspect(value)}"
  end

  defp validate_required_string!(_type, _field, _key, value)
       when is_binary(value) and value != "",
       do: :ok

  defp validate_required_string!(type, field, key, value) do
    raise ArgumentError,
          "step type #{type.id} field #{field} #{key} must be a non-empty string, got: #{inspect(value)}"
  end

  defp validate_optional_string!(_type, _field, _key, nil), do: :ok

  defp validate_optional_string!(_type, _field, _key, value)
       when is_binary(value) and value != "",
       do: :ok

  defp validate_optional_string!(type, field, key, value) do
    raise ArgumentError,
          "step type #{type.id} field #{field} #{key} must be a non-empty string, got: #{inspect(value)}"
  end

  defp validate_schema_property_references!(type, properties) when is_map(properties) do
    field_names = MapSet.new(Map.keys(properties))

    Enum.each(properties, fn {field, property} ->
      validate_property_references!(type, field, property, field_names)
    end)
  end

  defp validate_property_references!(type, field, property, field_names) when is_map(property) do
    property
    |> metadata_references()
    |> Enum.each(fn {metadata_path, field_name} ->
      unless MapSet.member?(field_names, field_name) do
        raise ArgumentError,
              "step type #{type.id} field #{field} #{metadata_path} references unknown field #{inspect(field_name)}"
      end
    end)
  end

  defp validate_property_references!(_type, _field, _property, _field_names), do: :ok

  defp metadata_references(property) do
    depends_on =
      property
      |> schema_depends_on()
      |> Enum.map(&{"depends_on", &1})

    mapper_references(schema_extension(property, "resource_mapper")) ++ depends_on
  end

  defp mapper_references(mapper) when is_map(mapper) do
    field_references =
      mapper
      |> Map.get("fields", %{})
      |> string_map_values("resource_mapper.fields")

    lookup_references =
      mapper
      |> Map.get("lookups", %{})
      |> Enum.flat_map(fn {lookup_name, lookup} ->
        case lookup do
          %{} ->
            lookup
            |> Map.get("params", %{})
            |> string_map_values("resource_mapper.lookups.#{lookup_name}.params")
            |> maybe_append_reference(
              "resource_mapper.lookups.#{lookup_name}.parent_option_field",
              Map.get(lookup, "parent_option_field")
            )

          _ ->
            []
        end
      end)

    field_references ++ lookup_references
  end

  defp mapper_references(_mapper), do: []

  defp string_map_values(value, path) when is_map(value) do
    Enum.map(value, fn {_key, field_name} -> {path, field_name} end)
  end

  defp string_map_values(_value, _path), do: []

  defp maybe_append_reference(references, _path, nil), do: references
  defp maybe_append_reference(references, path, value), do: [{path, value} | references]

  defp schema_depends_on(property) do
    case Map.get(property, "depends_on") || get_in(property, ["ui", "depends_on"]) do
      depends_on when is_list(depends_on) -> depends_on
      _ -> []
    end
  end

  defp schema_extension(property, key) when is_map(property) do
    Map.get(property, key) || get_in(property, ["ui", key])
  end

  defp schema_extension(_property, _key), do: nil

  defp validate_credential_field!(type, path, schema, default_config) do
    case get_in(schema, ["ui", "component"]) do
      "credential" -> validate_credential_field_shape!(type, path, schema, default_config)
      _component -> :ok
    end
  end

  defp validate_credential_field_shape!(type, path, schema, default_config) do
    ui = Map.get(schema, "ui", %{})
    provider = Map.get(ui, "provider")
    auth_type = Map.get(ui, "auth_type")
    requirement_key = Map.get(ui, "requirement_key")
    field = Enum.join(path, ".")

    with true <- is_binary(requirement_key) and requirement_key != "",
         true <- is_binary(provider) and provider != "",
         {:ok, auth_atom} <- credential_auth_type(auth_type),
         {:ok, _provider} <-
           Fizz.Integrations.ProviderCatalog.provider_for_type(provider, auth_atom),
         {:ok, default_value} <- fetch_nested(default_config, path),
         :ok <- validate_credential_default(default_value, provider, auth_type, requirement_key) do
      :ok
    else
      {:error, reason} ->
        raise ArgumentError,
              "step type #{type.id} credential field #{field} is invalid: #{inspect(reason)}"

      false ->
        raise ArgumentError,
              "step type #{type.id} credential field #{field} is missing credential metadata"

      other ->
        raise ArgumentError,
              "step type #{type.id} credential field #{field} is invalid: #{inspect(other)}"
    end
  end

  defp credential_auth_type("api_key"), do: {:ok, :api_key}
  defp credential_auth_type("oauth"), do: {:ok, :oauth}
  defp credential_auth_type(auth_type), do: {:error, {:unsupported_auth_type, auth_type}}

  defp validate_credential_default(
         %{
           "$credential" => true,
           "requirement_key" => requirement_key,
           "provider" => provider,
           "auth_type" => auth_type
         },
         provider,
         auth_type,
         requirement_key
       ),
       do: :ok

  defp validate_credential_default(default_value, _provider, _auth_type, _requirement_key) do
    {:error, {:missing_credential_default, default_value}}
  end

  defp fetch_nested(map, path) do
    case get_in(map, path) do
      nil -> {:error, {:missing_default_config, path}}
      value -> {:ok, value}
    end
  end

  defp get_type_default_config(type) do
    case type.default_config do
      default_config when is_map(default_config) and default_config != %{} ->
        default_config

      _default_config ->
        executor_default_config(type)
    end
  end

  defp executor_default_config(type) do
    with {:ok, module} <- StepType.executor_module(type),
         true <- function_exported?(module, :default_config, 0),
         default_config when is_map(default_config) <- module.default_config() do
      default_config
    else
      _ -> %{}
    end
  end
end
