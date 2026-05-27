defmodule Fizz.Fields do
  @moduledoc """
  Public field declaration API.

  Field structs are the source of truth. JSON Schema with the existing `"ui"`
  extension is adapter output for the current Vue field renderer.
  """

  alias Fizz.Fields.Definition

  @supported_types ~w(
    string
    number
    boolean
    json
    select
    search
    credential
    resource_locator
    resource_mapper
    hidden
    password
  )a

  @supported_components Enum.map(@supported_types, &Atom.to_string/1)

  @schema_types %{
    string: "string",
    number: "number",
    boolean: "boolean",
    json: "object",
    select: "string",
    search: "string",
    credential: "object",
    resource_locator: "string",
    resource_mapper: "object",
    hidden: "string",
    password: "string"
  }

  @spec supported_types() :: [atom()]
  def supported_types, do: @supported_types

  @spec supported_components() :: [String.t()]
  def supported_components, do: @supported_components

  @spec field(map() | keyword() | Definition.t()) :: Definition.t()
  def field(%Definition{} = field), do: normalize_field(field) |> validate!()

  def field(attrs) when is_list(attrs) do
    attrs
    |> Map.new()
    |> field()
  end

  def field(attrs) when is_map(attrs) do
    attrs = field_attrs(attrs)

    struct!(Definition, attrs)
    |> normalize_field()
    |> validate!()
  end

  @spec string(String.t(), keyword()) :: Definition.t()
  def string(key, opts \\ []), do: build(key, :string, opts)

  @spec number(String.t(), keyword()) :: Definition.t()
  def number(key, opts \\ []), do: build(key, :number, opts)

  @spec boolean(String.t(), keyword()) :: Definition.t()
  def boolean(key, opts \\ []), do: build(key, :boolean, opts)

  @spec json(String.t(), keyword()) :: Definition.t()
  def json(key, opts \\ []), do: build(key, :json, opts)

  @spec select(String.t(), keyword()) :: Definition.t()
  def select(key, opts \\ []), do: build(key, :select, opts)

  @spec search(String.t(), keyword()) :: Definition.t()
  def search(key, opts \\ []), do: build(key, :search, opts)

  @spec hidden(String.t(), keyword()) :: Definition.t()
  def hidden(key, opts \\ []) do
    key
    |> build(:hidden, opts)
    |> Map.put(:component, "hidden")
    |> validate!()
  end

  @spec password(String.t(), keyword()) :: Definition.t()
  def password(key, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:component, "password")
      |> Keyword.put_new(:secret?, true)
      |> Keyword.put_new(:write_only?, true)

    build(key, :password, opts)
  end

  @spec resource_locator(String.t(), map(), keyword()) :: Definition.t()
  def resource_locator(key, locator, opts \\ []) when is_map(locator) do
    opts =
      opts
      |> Keyword.put(:resource_locator, locator)
      |> Keyword.put_new(:component, "resource_locator")

    build(key, :resource_locator, opts)
  end

  @spec resource_mapper(String.t(), map(), keyword()) :: Definition.t()
  def resource_mapper(key, mapper, opts \\ []) when is_map(mapper) do
    opts =
      opts
      |> Keyword.put(:resource_mapper, mapper)
      |> Keyword.put_new(:component, "resource_mapper")

    build(key, :resource_mapper, opts)
  end

  @spec credential(String.t(), keyword()) :: Definition.t()
  def credential(provider, opts) when is_binary(provider) and is_list(opts) do
    auth_type = Keyword.fetch!(opts, :auth_type)
    credential(provider, auth_type, opts)
  end

  @spec credential(String.t(), :api_key | :oauth | String.t(), keyword()) :: Definition.t()
  def credential(provider, auth_type, opts \\ [])
      when is_binary(provider) and is_list(opts) do
    auth_type = normalize_auth_type!(auth_type)
    requirement_key = Keyword.get(opts, :requirement_key, "auth")
    key = Keyword.get(opts, :key, "credential_ref")

    opts =
      opts
      |> Keyword.drop([:auth_type, :requirement_key])
      |> Keyword.put(:key, key)
      |> Keyword.put(:type, :credential)
      |> Keyword.put_new(:label, "Credential")
      |> Keyword.put_new(:required?, true)
      |> Keyword.put_new(:component, "credential")
      |> Keyword.put(:credential, %{
        provider: provider,
        auth_type: auth_type,
        requirement_key: requirement_key
      })

    field(opts)
  end

  @spec to_schema([Definition.t()]) :: map()
  def to_schema(fields) when is_list(fields) do
    validated_fields = validate!(fields)
    required = for %Definition{key: key, required?: true} <- validated_fields, do: key

    %{
      "type" => "object",
      "properties" => Map.new(validated_fields, &{&1.key, to_schema_property(&1)})
    }
    |> maybe_put("required", required, required != [])
  end

  @spec to_schema_property(Definition.t()) :: map()
  def to_schema_property(%Definition{} = field) do
    field = validate!(field)

    %{
      "type" => Map.fetch!(@schema_types, field.type),
      "title" => field.label
    }
    |> maybe_put("description", field.description)
    |> maybe_put("default", field.default)
    |> maybe_put("writeOnly", true, field.write_only?)
    |> maybe_put("secret", true, field.secret?)
    |> maybe_put("enum", enum_values(field.options))
    |> maybe_put("options", field.options)
    |> maybe_put("depends_on", field.depends_on, field.depends_on != [])
    |> maybe_put("display", field.display)
    |> maybe_put("resource_locator", field.resource_locator)
    |> maybe_put("resource_mapper", field.resource_mapper)
    |> Map.put("ui", ui_schema(field))
  end

  @spec to_schema_property(Definition.t(), keyword()) :: map()
  def to_schema_property(%Definition{} = field, opts) when is_list(opts) do
    field
    |> apply_schema_opts(opts)
    |> to_schema_property()
  end

  @spec defaults([Definition.t()]) :: map()
  def defaults(fields) when is_list(fields) do
    fields
    |> validate!()
    |> Enum.reduce(%{}, fn field, defaults ->
      case default_value(field) do
        :no_default -> defaults
        value -> Map.put(defaults, field.key, value)
      end
    end)
  end

  @spec default_value(Definition.t()) :: term() | :no_default
  def default_value(%Definition{type: :credential, credential: credential}) do
    %{
      "$credential" => true,
      "requirement_key" => credential.requirement_key,
      "provider" => credential.provider,
      "auth_type" => Atom.to_string(credential.auth_type)
    }
  end

  def default_value(%Definition{default: nil}), do: :no_default
  def default_value(%Definition{default: value}), do: value

  @spec validate!([Definition.t()] | Definition.t()) :: [Definition.t()] | Definition.t()
  def validate!(fields) when is_list(fields), do: Enum.map(fields, &validate!/1)

  def validate!(%Definition{} = field) do
    validate_key!(field)
    validate_type!(field)
    validate_component!(field)
    validate_booleans!(field)
    validate_depends_on!(field)
    validate_resource_locator!(field)
    validate_resource_mapper!(field)
    validate_credential!(field)
    field
  end

  def validate!(field), do: raise(ArgumentError, "invalid field definition: #{inspect(field)}")

  defp build(key, type, opts) when is_binary(key) and is_list(opts) do
    opts
    |> Keyword.put(:key, key)
    |> Keyword.put(:type, type)
    |> field()
  end

  defp apply_schema_opts(%Definition{} = field, opts) do
    %{
      field
      | label: Keyword.get(opts, :label, field.label),
        description: Keyword.get(opts, :description, field.description)
    }
  end

  defp normalize_field(%Definition{} = field) do
    type = normalize_type!(field.type)
    key = normalize_required_string!(field.key, "field key")

    %{
      field
      | key: key,
        type: type,
        label: field.label || Phoenix.Naming.humanize(key),
        required?: normalize_required?(field),
        secret?: field.secret? == true,
        write_only?: field.write_only? == true,
        component: normalize_component(field.component),
        order: normalize_order(field.order),
        depends_on: normalize_string_list(field.depends_on),
        credential: normalize_credential(field.credential)
    }
  end

  defp normalize_required?(%Definition{required?: true}), do: true
  defp normalize_required?(%Definition{required?: false}), do: false

  defp normalize_required?(%Definition{} = field) do
    field
    |> Map.from_struct()
    |> Map.get(:required, false)
  end

  defp normalize_type!(type) when type in @supported_types, do: type

  defp normalize_type!(type) when is_binary(type) do
    case Enum.find(@supported_types, &(Atom.to_string(&1) == type)) do
      nil -> raise ArgumentError, "unsupported field type #{inspect(type)}"
      supported -> supported
    end
  end

  defp normalize_type!(type), do: raise(ArgumentError, "unsupported field type #{inspect(type)}")

  defp normalize_component(nil), do: nil
  defp normalize_component(component) when is_binary(component), do: component
  defp normalize_component(component) when is_atom(component), do: Atom.to_string(component)
  defp normalize_component(component), do: component

  defp normalize_order(order) when is_integer(order), do: order
  defp normalize_order(_order), do: 100

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(_values), do: []

  defp normalize_credential(nil), do: nil

  defp normalize_credential(credential) when is_map(credential) do
    %{
      provider:
        normalize_required_string!(map_value(credential, :provider), "credential provider"),
      auth_type: normalize_auth_type!(map_value(credential, :auth_type)),
      requirement_key:
        normalize_required_string!(
          map_value(credential, :requirement_key),
          "credential requirement_key"
        )
    }
  end

  defp normalize_credential(credential), do: credential

  defp normalize_auth_type!(:api_key), do: :api_key
  defp normalize_auth_type!(:oauth), do: :oauth
  defp normalize_auth_type!("api_key"), do: :api_key
  defp normalize_auth_type!("oauth"), do: :oauth

  defp normalize_auth_type!(auth_type) do
    raise ArgumentError, "unsupported credential auth_type #{inspect(auth_type)}"
  end

  defp normalize_required_string!(value, label) when is_binary(value) do
    case String.trim(value) do
      "" -> raise ArgumentError, "#{label} must be a non-empty string"
      value -> value
    end
  end

  defp normalize_required_string!(value, label) do
    raise ArgumentError, "#{label} must be a non-empty string, got: #{inspect(value)}"
  end

  defp validate_key!(%Definition{key: key}) when is_binary(key) and key != "", do: :ok
  defp validate_key!(field), do: raise(ArgumentError, "field key is required: #{inspect(field)}")

  defp validate_type!(%Definition{type: type}) when type in @supported_types, do: :ok

  defp validate_type!(%Definition{type: type}) do
    raise ArgumentError, "unsupported field type #{inspect(type)}"
  end

  defp validate_component!(%Definition{} = field) do
    component = field.component || inferred_component(field.type)

    unless component in @supported_components do
      raise ArgumentError, "field #{field.key} uses unsupported component #{inspect(component)}"
    end
  end

  defp validate_booleans!(%Definition{
         required?: required?,
         secret?: secret?,
         write_only?: write_only?
       }) do
    unless is_boolean(required?) and is_boolean(secret?) and is_boolean(write_only?) do
      raise ArgumentError, "field boolean flags must be true or false"
    end
  end

  defp validate_depends_on!(%Definition{depends_on: depends_on} = field) do
    unless is_list(depends_on) and Enum.all?(depends_on, &is_binary/1) do
      raise ArgumentError, "field #{field.key} depends_on must contain only strings"
    end
  end

  defp validate_resource_locator!(%Definition{type: :resource_locator, resource_locator: nil}) do
    raise ArgumentError, "resource_locator field requires resource_locator metadata"
  end

  defp validate_resource_locator!(%Definition{resource_locator: nil}), do: :ok

  defp validate_resource_locator!(%Definition{key: key, resource_locator: locator})
       when is_map(locator) do
    validate_metadata_string!(key, locator, "resource_locator", "kind")
    validate_optional_metadata_string!(key, locator, "resource_locator", "value_key")
  end

  defp validate_resource_locator!(%Definition{key: key, resource_locator: locator}) do
    raise ArgumentError, "field #{key} resource_locator must be a map, got: #{inspect(locator)}"
  end

  defp validate_resource_mapper!(%Definition{type: :resource_mapper, resource_mapper: nil}) do
    raise ArgumentError, "resource_mapper field requires resource_mapper metadata"
  end

  defp validate_resource_mapper!(%Definition{resource_mapper: nil}), do: :ok

  defp validate_resource_mapper!(%Definition{key: key, resource_mapper: mapper})
       when is_map(mapper) do
    validate_metadata_string!(key, mapper, "resource_mapper", "kind")
    validate_optional_string_value_map!(key, mapper, "resource_mapper", "fields")
    validate_optional_string_value_map!(key, mapper, "resource_mapper", "labels")
    validate_resource_mapper_lookups!(key, mapper)
    validate_resource_mapper_errors!(key, mapper)
  end

  defp validate_resource_mapper!(%Definition{key: key, resource_mapper: mapper}) do
    raise ArgumentError, "field #{key} resource_mapper must be a map, got: #{inspect(mapper)}"
  end

  defp validate_credential!(%Definition{type: :credential, credential: credential})
       when is_map(credential) do
    validate_metadata_value!("credential field", credential.provider, "provider")
    validate_metadata_value!("credential field", credential.requirement_key, "requirement_key")

    unless credential.auth_type in [:api_key, :oauth] do
      raise ArgumentError, "credential field auth_type must be api_key or oauth"
    end
  end

  defp validate_credential!(%Definition{type: :credential, credential: credential}) do
    raise ArgumentError,
          "credential field requires credential metadata, got: #{inspect(credential)}"
  end

  defp validate_credential!(%Definition{credential: nil}), do: :ok

  defp validate_credential!(%Definition{key: key}) do
    raise ArgumentError, "field #{key} credential metadata is only valid for credential fields"
  end

  defp validate_metadata_string!(field_key, metadata, metadata_key, value_key) do
    validate_metadata_value!(
      "field #{field_key} #{metadata_key}",
      Map.get(metadata, value_key),
      value_key
    )
  end

  defp validate_optional_metadata_string!(_field_key, metadata, _metadata_key, value_key)
       when not is_map_key(metadata, value_key),
       do: :ok

  defp validate_optional_metadata_string!(field_key, metadata, metadata_key, value_key) do
    validate_metadata_string!(field_key, metadata, metadata_key, value_key)
  end

  defp validate_metadata_value!(_label, value, _key) when is_binary(value) and value != "",
    do: :ok

  defp validate_metadata_value!(label, value, key) do
    raise ArgumentError, "#{label}.#{key} must be a non-empty string, got: #{inspect(value)}"
  end

  defp validate_optional_string_value_map!(_field_key, metadata, _metadata_key, key)
       when not is_map_key(metadata, key),
       do: :ok

  defp validate_optional_string_value_map!(field_key, metadata, metadata_key, key) do
    case Map.get(metadata, key) do
      values when is_map(values) ->
        Enum.each(values, fn {entry_key, entry_value} ->
          validate_metadata_value!(
            "field #{field_key} #{metadata_key}.#{key}",
            entry_value,
            entry_key
          )
        end)

      value ->
        raise ArgumentError,
              "field #{field_key} #{metadata_key}.#{key} must be a map, got: #{inspect(value)}"
    end
  end

  defp validate_resource_mapper_lookups!(field_key, mapper) do
    case Map.get(mapper, "lookups") do
      nil ->
        :ok

      lookups when is_map(lookups) ->
        Enum.each(lookups, fn {lookup_name, lookup} ->
          validate_resource_mapper_lookup!(field_key, lookup_name, lookup)
        end)

      value ->
        raise ArgumentError,
              "field #{field_key} resource_mapper.lookups must be a map, got: #{inspect(value)}"
    end
  end

  defp validate_resource_mapper_lookup!(field_key, lookup_name, lookup) when is_map(lookup) do
    validate_metadata_value!(
      "field #{field_key} resource_mapper.lookups.#{lookup_name}",
      Map.get(lookup, "mode"),
      "mode"
    )

    validate_optional_string_value_map!(
      field_key,
      lookup,
      "resource_mapper.lookups.#{lookup_name}",
      "params"
    )

    validate_optional_metadata_string!(
      field_key,
      lookup,
      "resource_mapper.lookups.#{lookup_name}",
      "parent_option_field"
    )
  end

  defp validate_resource_mapper_lookup!(field_key, lookup_name, lookup) do
    raise ArgumentError,
          "field #{field_key} resource_mapper.lookups.#{lookup_name} must be a map, got: #{inspect(lookup)}"
  end

  defp validate_resource_mapper_errors!(field_key, mapper) do
    case Map.get(mapper, "errors") do
      nil ->
        :ok

      errors when is_map(errors) ->
        Enum.each(errors, fn {scope, messages} ->
          validate_error_messages!(field_key, scope, messages)
        end)

      value ->
        raise ArgumentError,
              "field #{field_key} resource_mapper.errors must be a map, got: #{inspect(value)}"
    end
  end

  defp validate_error_messages!(field_key, scope, messages) when is_map(messages) do
    Enum.each(messages, fn {reason, message} ->
      validate_metadata_value!(
        "field #{field_key} resource_mapper.errors.#{scope}",
        message,
        reason
      )
    end)
  end

  defp validate_error_messages!(field_key, scope, messages) do
    raise ArgumentError,
          "field #{field_key} resource_mapper.errors.#{scope} must be a map, got: #{inspect(messages)}"
  end

  defp inferred_component(type), do: Atom.to_string(type)

  defp ui_schema(%Definition{} = field) do
    %{
      "component" => field.component || inferred_component(field.type)
    }
    |> Map.merge(credential_ui(field))
    |> maybe_put("placeholder", field.placeholder)
    |> maybe_put("autocomplete", field.autocomplete)
    |> maybe_put("order", field.order)
    |> maybe_put("resolver", field.resolver)
    |> maybe_put("params", resolver_params(field))
    |> maybe_put("depends_on", field.depends_on, field.depends_on != [])
    |> maybe_put("options", field.options)
    |> maybe_put("display", field.display)
    |> maybe_put("resource_locator", field.resource_locator)
    |> maybe_put("resource_mapper", field.resource_mapper)
  end

  defp resolver_params(%Definition{type: :credential, credential: credential}) do
    %{
      "provider_filter" => credential.provider,
      "auth_types" => Atom.to_string(credential.auth_type)
    }
  end

  defp resolver_params(_field), do: nil

  defp credential_ui(%Definition{type: :credential, credential: credential}) do
    %{
      "requirement_key" => credential.requirement_key,
      "provider" => credential.provider,
      "auth_type" => Atom.to_string(credential.auth_type)
    }
  end

  defp credential_ui(_field), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp maybe_put(map, _key, [], _condition), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)
  defp maybe_put(map, _key, _value, false), do: map

  defp enum_values(options) when is_list(options) do
    options
    |> Enum.map(&map_value(&1, :value))
    |> Enum.reject(&is_nil/1)
  end

  defp enum_values(_options), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field_attrs(attrs) when is_map(attrs) do
    attrs
    |> Enum.flat_map(&field_attr/1)
    |> Map.new()
  end

  defp field_attr({:required, value}), do: [{:required?, value}]
  defp field_attr({"required", value}), do: [{:required?, value}]
  defp field_attr({"required?", value}), do: [{:required?, value}]
  defp field_attr({key, value}) when is_atom(key), do: [{key, value}]
  defp field_attr({"key", value}), do: [{:key, value}]
  defp field_attr({"type", value}), do: [{:type, value}]
  defp field_attr({"label", value}), do: [{:label, value}]
  defp field_attr({"description", value}), do: [{:description, value}]
  defp field_attr({"default", value}), do: [{:default, value}]
  defp field_attr({"secret?", value}), do: [{:secret?, value}]
  defp field_attr({"secret", value}), do: [{:secret?, value}]
  defp field_attr({"write_only?", value}), do: [{:write_only?, value}]
  defp field_attr({"write_only", value}), do: [{:write_only?, value}]
  defp field_attr({"component", value}), do: [{:component, value}]
  defp field_attr({"placeholder", value}), do: [{:placeholder, value}]
  defp field_attr({"autocomplete", value}), do: [{:autocomplete, value}]
  defp field_attr({"order", value}), do: [{:order, value}]
  defp field_attr({"resolver", value}), do: [{:resolver, value}]
  defp field_attr({"depends_on", value}), do: [{:depends_on, value}]
  defp field_attr({"options", value}), do: [{:options, value}]
  defp field_attr({"display", value}), do: [{:display, value}]
  defp field_attr({"resource_locator", value}), do: [{:resource_locator, value}]
  defp field_attr({"resource_mapper", value}), do: [{:resource_mapper, value}]
  defp field_attr({"credential", value}), do: [{:credential, value}]
  defp field_attr({_key, _value}), do: []
end
