defmodule Fizz.Integrations.Definition do
  @moduledoc """
  Validators and normalization helpers for unified integration definitions.
  """

  alias Fizz.Integrations.{
    CredentialRequirement,
    OperationDefinition,
    RetryPolicy
  }

  @supported_field_components ~w(credential hidden json number password resource_locator resource_mapper search select string)

  @spec validate_operation!(OperationDefinition.t()) :: OperationDefinition.t()
  def validate_operation!(%OperationDefinition{} = operation) do
    validate_required_string!(operation.id, "operation id")
    validate_required_string!(operation.step_type_id, "operation step_type_id")
    validate_required_string!(operation.provider, "operation provider")
    validate_required_string!(operation.integration, "operation integration")
    validate_positive_integer!(operation.version, "operation version")
    validate_module!(operation.module, "operation #{operation.id} module")
    validate_operation_module!(operation)
    validate_display!(operation.id, operation.display)
    validate_schema!("operation #{operation.id} config_schema", operation.config_schema)
    validate_schema!("operation #{operation.id} input_schema", operation.input_schema)
    validate_schema!("operation #{operation.id} output_schema", operation.output_schema)
    Enum.each(operation.auth, &validate_credential_requirement!/1)
    validate_retry_policy!(operation.retry)

    operation
  end

  def validate_operation!(operation) do
    raise ArgumentError, "invalid operation definition: #{inspect(operation)}"
  end

  @spec validate_operations!([OperationDefinition.t()]) :: [OperationDefinition.t()]
  def validate_operations!(operations) when is_list(operations) do
    operations
    |> validate_unique_by!(& &1.id, "operation IDs")
    |> validate_unique_by!(&{&1.step_type_id, &1.version}, "operation step versions")
    |> Enum.map(&validate_operation!/1)
  end

  def validate_operations!(operations) do
    raise ArgumentError, "operation definitions must be a list, got: #{inspect(operations)}"
  end

  @spec validate_credential!(struct()) :: struct()
  def validate_credential!(%Fizz.Integrations.Definition.Credential{} = credential) do
    validate_required_string!(credential.id, "credential id")
    validate_required_string!(credential.provider, "credential provider")
    validate_display_map!(credential.id, credential.display)
    validate_schema!("credential #{credential.id} ui_schema", credential.ui_schema)

    unless credential.auth_type in [:oauth, :api_key] do
      raise ArgumentError,
            "credential #{credential.id} has unsupported auth_type #{inspect(credential.auth_type)}"
    end

    credential
  end

  def validate_credential!(credential) do
    raise ArgumentError, "invalid credential definition: #{inspect(credential)}"
  end

  @spec validate_credentials!([struct()]) :: [struct()]
  def validate_credentials!(credentials) when is_list(credentials) do
    credentials
    |> validate_unique_by!(& &1.id, "credential IDs")
    |> Enum.map(&validate_credential!/1)
  end

  def validate_credentials!(credentials) do
    raise ArgumentError, "credential definitions must be a list, got: #{inspect(credentials)}"
  end

  @spec supported_field_components() :: [String.t()]
  def supported_field_components, do: @supported_field_components

  defp validate_credential_requirement!(%CredentialRequirement{} = requirement) do
    validate_required_string!(requirement.key, "credential requirement key")
    validate_required_string!(requirement.provider, "credential requirement provider")

    validate_required_string!(
      requirement.requirement_key,
      "credential requirement requirement_key"
    )

    unless requirement.auth_type in [:oauth, :api_key] do
      raise ArgumentError,
            "credential requirement #{requirement.key} has unsupported auth_type #{inspect(requirement.auth_type)}"
    end

    requirement
  end

  defp validate_credential_requirement!(requirement) do
    raise ArgumentError, "invalid credential requirement: #{inspect(requirement)}"
  end

  defp validate_retry_policy!(%RetryPolicy{max_attempts: max_attempts, backoff: backoff})
       when is_integer(max_attempts) and max_attempts > 0 and
              backoff in [:none, :linear, :exponential],
       do: :ok

  defp validate_retry_policy!(retry) do
    raise ArgumentError, "invalid retry policy: #{inspect(retry)}"
  end

  defp validate_operation_module!(%OperationDefinition{} = operation) do
    behaviours =
      operation.module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    unless Fizz.Integrations.Operation in behaviours do
      raise ArgumentError,
            "operation #{operation.id} module #{inspect(operation.module)} must implement Fizz.Integrations.Operation"
    end

    operation_id = operation.id

    case operation.module.id() do
      ^operation_id ->
        :ok

      id ->
        raise ArgumentError,
              "operation #{operation.id} module ID mismatch: #{inspect(id)}"
    end
  end

  defp validate_display!(operation_id, %{"name" => name} = display) when is_binary(name) do
    validate_display_icon!(operation_id, display)
  end

  defp validate_display!(operation_id, %{name: name} = display) when is_binary(name) do
    validate_display_icon!(operation_id, display)
  end

  defp validate_display!(operation_id, display) do
    raise ArgumentError, "operation #{operation_id} display requires a name: #{inspect(display)}"
  end

  defp validate_display_map!(credential_id, %{} = display) do
    case display[:label] || display["label"] do
      label when is_binary(label) and label != "" ->
        :ok

      _label ->
        raise ArgumentError, "credential #{credential_id} display requires a label"
    end
  end

  defp validate_display_map!(credential_id, display) do
    raise ArgumentError, "credential #{credential_id} display must be a map: #{inspect(display)}"
  end

  defp validate_display_icon!(operation_id, display) do
    icon = display[:icon] || display["icon"]

    case icon do
      value when is_binary(value) and value != "" ->
        :ok

      _ ->
        raise ArgumentError, "operation #{operation_id} display requires an icon"
    end
  end

  defp validate_schema!(label, %{"type" => "object"} = schema) do
    properties = Map.get(schema, "properties", %{})

    schema
    |> Map.get("properties", %{})
    |> Enum.each(fn {field, property} ->
      validate_schema_property!("#{label}.#{field}", property)
    end)

    validate_schema_property_references!(label, properties)
  end

  defp validate_schema!(label, schema) when is_map(schema) do
    raise ArgumentError, "#{label} must be an object schema: #{inspect(schema)}"
  end

  defp validate_schema!(label, schema) do
    raise ArgumentError, "#{label} must be a schema map: #{inspect(schema)}"
  end

  defp validate_schema_property!(label, property) when is_map(property) do
    validate_schema_property_extensions!(label, property)

    case get_in(property, ["ui", "component"]) do
      nil ->
        :ok

      component when component in @supported_field_components ->
        :ok

      component ->
        raise ArgumentError, "#{label} uses unsupported ui.component #{inspect(component)}"
    end
  end

  defp validate_schema_property!(_label, _property), do: :ok

  defp validate_schema_property_extensions!(label, property) do
    validate_depends_on!(
      label,
      Map.get(property, "depends_on") || get_in(property, ["ui", "depends_on"])
    )

    validate_optional_map!(label, "display", Map.get(property, "display"))
    validate_resource_locator!(label, "resource_locator", Map.get(property, "resource_locator"))
    validate_resource_mapper!(label, "resource_mapper", Map.get(property, "resource_mapper"))

    validate_optional_map!(
      label,
      "ui.display",
      get_in(property, ["ui", "display"])
    )

    validate_optional_map!(
      label,
      "ui.resource_locator",
      get_in(property, ["ui", "resource_locator"])
    )

    validate_resource_locator!(
      label,
      "ui.resource_locator",
      get_in(property, ["ui", "resource_locator"])
    )

    validate_resource_mapper!(
      label,
      "ui.resource_mapper",
      get_in(property, ["ui", "resource_mapper"])
    )
  end

  defp validate_depends_on!(_label, nil), do: :ok

  defp validate_depends_on!(label, depends_on) when is_list(depends_on) do
    unless Enum.all?(depends_on, &is_binary/1) do
      raise ArgumentError, "#{label} depends_on must contain only strings"
    end
  end

  defp validate_depends_on!(label, depends_on) do
    raise ArgumentError, "#{label} depends_on must be a list, got: #{inspect(depends_on)}"
  end

  defp validate_optional_map!(_label, _key, nil), do: :ok
  defp validate_optional_map!(_label, _key, value) when is_map(value), do: :ok

  defp validate_optional_map!(label, key, value) do
    raise ArgumentError, "#{label} #{key} must be a map, got: #{inspect(value)}"
  end

  defp validate_resource_locator!(_label, _key, nil), do: :ok

  defp validate_resource_locator!(label, key, locator) when is_map(locator) do
    validate_required_string!(Map.get(locator, "kind"), "#{label} #{key}.kind")
    validate_optional_string!(label, "#{key}.value_key", Map.get(locator, "value_key"))
  end

  defp validate_resource_locator!(label, key, value) do
    raise ArgumentError, "#{label} #{key} must be a map, got: #{inspect(value)}"
  end

  defp validate_resource_mapper!(_label, _key, nil), do: :ok

  defp validate_resource_mapper!(label, key, mapper) when is_map(mapper) do
    validate_required_string!(Map.get(mapper, "kind"), "#{label} #{key}.kind")
    validate_string_value_map!(label, "#{key}.fields", Map.get(mapper, "fields"))
    validate_string_value_map!(label, "#{key}.labels", Map.get(mapper, "labels"))
    validate_resource_mapper_lookups!(label, key, Map.get(mapper, "lookups"))
    validate_resource_mapper_errors!(label, key, Map.get(mapper, "errors"))
  end

  defp validate_resource_mapper!(label, key, value) do
    raise ArgumentError, "#{label} #{key} must be a map, got: #{inspect(value)}"
  end

  defp validate_resource_mapper_lookups!(_label, _key, nil), do: :ok

  defp validate_resource_mapper_lookups!(label, key, lookups) when is_map(lookups) do
    Enum.each(lookups, fn {lookup_name, lookup} ->
      lookup_label = "#{label} #{key}.lookups.#{lookup_name}"

      case lookup do
        %{} ->
          validate_required_string!(Map.get(lookup, "mode"), "#{lookup_label}.mode")

          validate_string_value_map!(
            label,
            "#{key}.lookups.#{lookup_name}.params",
            Map.get(lookup, "params")
          )

          validate_optional_string!(
            label,
            "#{key}.lookups.#{lookup_name}.parent_option_field",
            Map.get(lookup, "parent_option_field")
          )

        _ ->
          raise ArgumentError, "#{lookup_label} must be a map, got: #{inspect(lookup)}"
      end
    end)
  end

  defp validate_resource_mapper_lookups!(label, key, value) do
    raise ArgumentError, "#{label} #{key}.lookups must be a map, got: #{inspect(value)}"
  end

  defp validate_resource_mapper_errors!(_label, _key, nil), do: :ok

  defp validate_resource_mapper_errors!(label, key, errors) when is_map(errors) do
    Enum.each(errors, fn {scope, messages} ->
      case messages do
        %{} ->
          validate_string_value_map!(label, "#{key}.errors.#{scope}", messages)

        _ ->
          raise ArgumentError,
                "#{label} #{key}.errors.#{scope} must be a map, got: #{inspect(messages)}"
      end
    end)
  end

  defp validate_resource_mapper_errors!(label, key, value) do
    raise ArgumentError, "#{label} #{key}.errors must be a map, got: #{inspect(value)}"
  end

  defp validate_string_value_map!(_label, _key, nil), do: :ok

  defp validate_string_value_map!(label, key, value) when is_map(value) do
    Enum.each(value, fn {entry_key, entry_value} ->
      validate_required_string!(entry_value, "#{label} #{key}.#{entry_key}")
    end)
  end

  defp validate_string_value_map!(label, key, value) do
    raise ArgumentError, "#{label} #{key} must be a map, got: #{inspect(value)}"
  end

  defp validate_optional_string!(_label, _key, nil), do: :ok

  defp validate_optional_string!(_label, _key, value) when is_binary(value) and value != "",
    do: :ok

  defp validate_optional_string!(label, key, value) do
    raise ArgumentError, "#{label} #{key} must be a non-empty string, got: #{inspect(value)}"
  end

  defp validate_schema_property_references!(label, properties) when is_map(properties) do
    field_names = MapSet.new(Map.keys(properties))

    Enum.each(properties, fn {field, property} ->
      validate_property_references!("#{label}.#{field}", property, field_names)
    end)
  end

  defp validate_property_references!(label, property, field_names) when is_map(property) do
    property
    |> metadata_references()
    |> Enum.each(fn {metadata_path, field_name} ->
      unless MapSet.member?(field_names, field_name) do
        raise ArgumentError,
              "#{label} #{metadata_path} references unknown field #{inspect(field_name)}"
      end
    end)
  end

  defp validate_property_references!(_label, _property, _field_names), do: :ok

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

  defp validate_required_string!(value, _label) when is_binary(value) and value != "", do: :ok

  defp validate_required_string!(value, label) do
    raise ArgumentError, "#{label} must be a non-empty string, got: #{inspect(value)}"
  end

  defp validate_positive_integer!(value, _label) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_integer!(value, label) do
    raise ArgumentError, "#{label} must be a positive integer, got: #{inspect(value)}"
  end

  defp validate_module!(module, label) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> :ok
      _ -> raise ArgumentError, "#{label} is not loaded: #{inspect(module)}"
    end
  end

  defp validate_module!(module, label) do
    raise ArgumentError, "#{label} must be a module, got: #{inspect(module)}"
  end

  defp validate_unique_by!(entries, mapper, label) do
    duplicate_values =
      entries
      |> Enum.map(mapper)
      |> Enum.frequencies()
      |> Enum.filter(fn {_value, count} -> count > 1 end)
      |> Enum.map(fn {value, _count} -> value end)
      |> Enum.sort()

    case duplicate_values do
      [] -> entries
      values -> raise ArgumentError, "duplicate #{label}: #{inspect(values)}"
    end
  end
end
