defmodule Fizz.Integrations.Steps.ConnectionHandles do
  @moduledoc """
  Reads workflow connection handles from step input and output schemas.

  Config fields stay in `Fizz.Fields`; this module only deals with graph
  topology metadata declared on `input_schema` and `output_schema`.
  """

  alias Fizz.Integrations.Steps.Type, as: StepType
  alias Fizz.Workflows.Expressions.AccessPlan

  @default_handle "main"
  @type handle_kind :: :flow | :dependency
  @type cardinality :: :one | :many
  @type input_handle :: %{
          id: String.t(),
          key: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          kind: handle_kind(),
          cardinality: cardinality(),
          required?: boolean(),
          accepts: %{provides: [String.t()]}
        }
  @type output_handle :: %{
          id: String.t(),
          kind: handle_kind(),
          provides: [String.t()]
        }

  @spec input_handles(StepType.t() | map()) :: [input_handle()]
  def input_handles(%StepType{input_schema: schema}), do: input_handles(schema)

  def input_handles(%{input_schema: schema}) when is_map(schema), do: input_handles(schema)

  def input_handles(schema) when is_map(schema) do
    properties = Map.get(schema, "properties", %{})
    required = schema |> Map.get("required", []) |> MapSet.new()

    handles =
      properties
      |> Enum.flat_map(fn {key, property_schema} ->
        case input_connection_metadata(property_schema, key) do
          nil -> []
          connection -> [input_handle_from_property(key, property_schema, connection, required)]
        end
      end)

    case Enum.any?(handles, &(&1.id == @default_handle)) do
      true -> handles
      false -> [default_input_handle() | handles]
    end
  end

  def input_handles(_schema), do: [default_input_handle()]

  @spec output_handles(StepType.t() | map()) :: {:ok, [output_handle()]} | {:error, String.t()}
  def output_handles(%StepType{output_schema: schema}), do: output_handles(schema, %{})

  def output_handles(%{output_schema: schema} = step) when is_map(schema) do
    output_handles(schema, Map.get(step, :compiled_config, %{}))
  end

  def output_handles(schema) when is_map(schema), do: output_handles(schema, %{})

  def output_handles(schema, compiled_config) when is_map(schema) do
    schema
    |> output_handle_specs()
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, handles} ->
      case output_handles_from_spec(spec, schema, compiled_config) do
        {:ok, spec_handles} -> {:cont, {:ok, handles ++ spec_handles}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, handles} -> {:ok, dedupe_output_handles(handles)}
      {:error, _message} = error -> error
    end
  end

  def output_handles(_schema, _compiled_config), do: {:ok, [default_output_handle([])]}

  @spec validate_step_type!(StepType.t()) :: StepType.t()
  def validate_step_type!(%StepType{} = type) do
    validate_input_schema!(type, type.input_schema || %{})
    validate_output_schema!(type, type.output_schema || %{})
    type
  end

  defp input_connection_metadata(property_schema, key) when is_map(property_schema) do
    case Map.get(property_schema, "connection") do
      nil when key == @default_handle ->
        %{"kind" => "flow"}

      nil ->
        nil

      connection when is_map(connection) ->
        connection

      connection ->
        raise ArgumentError, "connection metadata must be a map, got: #{inspect(connection)}"
    end
  end

  defp input_connection_metadata(_property_schema, _key), do: nil

  defp input_handle_from_property(key, property_schema, connection, required) do
    id = Map.get(connection, "handle", key)

    %{
      id: id,
      key: key,
      title: Map.get(property_schema, "title"),
      description: Map.get(property_schema, "description"),
      kind: normalize_kind(Map.get(connection, "kind", "flow")),
      cardinality: normalize_cardinality(Map.get(connection, "cardinality", "one")),
      required?: MapSet.member?(required, key),
      accepts: normalize_accepts(Map.get(connection, "accepts", %{}))
    }
  end

  defp default_input_handle do
    %{
      id: @default_handle,
      key: @default_handle,
      title: "Input",
      description: nil,
      kind: :flow,
      cardinality: :one,
      required?: false,
      accepts: %{provides: []}
    }
  end

  defp output_handle_specs(%{"outputs" => outputs}) when is_list(outputs), do: outputs
  defp output_handle_specs(_schema), do: [%{"id" => @default_handle, "kind" => "flow"}]

  defp output_handles_from_spec(spec, schema, compiled_config) when is_map(spec) do
    kind = normalize_kind(Map.get(spec, "kind", "flow"))
    provides = normalize_provides(Map.get(spec, "provides", Map.get(schema, "provides", [])))

    cond do
      is_binary(Map.get(spec, "dynamic_outputs_from")) ->
        spec
        |> Map.fetch!("dynamic_outputs_from")
        |> dynamic_output_ids(compiled_config)
        |> case do
          {:ok, output_ids} ->
            {:ok, Enum.map(output_ids, &%{id: &1, kind: kind, provides: provides})}

          {:error, _message} = error ->
            error
        end

      true ->
        case static_output_id(spec, compiled_config) do
          {:ok, id} -> {:ok, [%{id: id, kind: kind, provides: provides}]}
          {:error, _message} = error -> error
        end
    end
  end

  defp output_handles_from_spec(spec, _schema, _compiled_config) do
    {:error, "output handle declaration must be a map, got: #{inspect(spec)}"}
  end

  defp static_output_id(spec, compiled_config) do
    fallback = Map.get(spec, "id")

    case Map.get(spec, "config_key") do
      key when is_binary(key) ->
        compiled_config
        |> Map.get(key)
        |> literal_string_or_default(fallback, "output handle #{key}")

      nil ->
        non_empty_string(fallback, "output handle id")

      value ->
        {:error, "output handle config_key must be a non-empty string, got: #{inspect(value)}"}
    end
  end

  defp dynamic_output_ids(pattern, compiled_config) do
    with {:ok, collection_key, field_key} <- parse_dynamic_outputs_from(pattern),
         {:ok, values} <- dynamic_values(compiled_config, collection_key, field_key) do
      {:ok, Enum.uniq(values)}
    end
  end

  defp parse_dynamic_outputs_from(pattern) when is_binary(pattern) do
    case String.split(pattern, "[].", parts: 2) do
      [collection_key, field_key] when collection_key != "" and field_key != "" ->
        {:ok, collection_key, field_key}

      _ ->
        {:error,
         "dynamic_outputs_from must use collection[].field syntax, got: #{inspect(pattern)}"}
    end
  end

  defp dynamic_values(compiled_config, collection_key, field_key) do
    collection =
      compiled_config
      |> Map.get(collection_key, [])
      |> literal_value()

    case collection do
      values when is_list(values) ->
        values
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
          field_value =
            value
            |> literal_value()
            |> value_at(field_key)
            |> literal_value()

          case non_empty_string(field_value, "#{collection_key}[#{index}].#{field_key}") do
            {:ok, output_id} -> {:cont, {:ok, acc ++ [output_id]}}
            {:error, _message} = error -> {:halt, error}
          end
        end)

      other ->
        {:error, "#{collection_key} must resolve to a list, got: #{inspect(other)}"}
    end
  end

  defp literal_string_or_default(nil, fallback, label), do: non_empty_string(fallback, label)

  defp literal_string_or_default(%AccessPlan.Literal{value: nil}, fallback, label),
    do: non_empty_string(fallback, label)

  defp literal_string_or_default(%AccessPlan.Literal{value: value}, _fallback, label),
    do: non_empty_string(value, label)

  defp literal_string_or_default(value, _fallback, label),
    do: non_empty_string(literal_value(value), label)

  defp literal_value(%AccessPlan.Literal{value: value}), do: value
  defp literal_value(value), do: value

  defp value_at(map, key) when is_map(map), do: Map.get(map, key)
  defp value_at(_value, _key), do: nil

  defp non_empty_string(value, _label) when is_binary(value) and value != "", do: {:ok, value}

  defp non_empty_string(value, label) do
    {:error, "#{label} must resolve to a non-empty string, got: #{inspect(value)}"}
  end

  defp default_output_handle(provides) do
    %{id: @default_handle, kind: :flow, provides: provides}
  end

  defp dedupe_output_handles(handles) do
    {_seen, deduped} =
      Enum.reduce(handles, {MapSet.new(), []}, fn handle, {seen, acc} ->
        case MapSet.member?(seen, handle.id) do
          true -> {seen, acc}
          false -> {MapSet.put(seen, handle.id), acc ++ [handle]}
        end
      end)

    deduped
  end

  defp validate_input_schema!(type, schema) when is_map(schema) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])

    unless is_map(properties) do
      raise ArgumentError, "step type #{type.id} input_schema.properties must be a map"
    end

    unless is_list(required) and Enum.all?(required, &is_binary/1) do
      raise ArgumentError, "step type #{type.id} input_schema.required must be a list of strings"
    end

    property_keys = MapSet.new(Map.keys(properties))

    Enum.each(required, fn key ->
      unless MapSet.member?(property_keys, key) do
        raise ArgumentError,
              "step type #{type.id} input_schema.required references unknown property #{inspect(key)}"
      end
    end)

    handles = input_handles(schema)
    validate_unique_handle_ids!(type, "input", handles)
    type
  end

  defp validate_input_schema!(type, schema) do
    raise ArgumentError,
          "step type #{type.id} input_schema must be a map, got: #{inspect(schema)}"
  end

  defp validate_output_schema!(type, schema) when is_map(schema) do
    specs = output_handle_specs(schema)

    unless is_list(specs) do
      raise ArgumentError, "step type #{type.id} output_schema.outputs must be a list"
    end

    specs
    |> Enum.each(&validate_output_spec!(type, &1))

    specs
    |> Enum.filter(&is_map/1)
    |> Enum.reject(&Map.has_key?(&1, "dynamic_outputs_from"))
    |> Enum.map(fn spec -> Map.get(spec, "id") end)
    |> Enum.reject(&is_nil/1)
    |> validate_no_duplicate_static_outputs!(type)

    schema
    |> Map.get("provides", [])
    |> normalize_provides()

    type
  end

  defp validate_output_schema!(type, schema) do
    raise ArgumentError,
          "step type #{type.id} output_schema must be a map, got: #{inspect(schema)}"
  end

  defp validate_output_spec!(type, spec) when is_map(spec) do
    spec
    |> Map.get("kind", "flow")
    |> normalize_kind()

    spec
    |> Map.get("provides", [])
    |> normalize_provides()

    cond do
      is_binary(Map.get(spec, "dynamic_outputs_from")) ->
        :ok

      Map.has_key?(spec, "config_key") ->
        validate_required_schema_string!(type, "output config_key", Map.get(spec, "config_key"))
        validate_required_schema_string!(type, "output id", Map.get(spec, "id"))

      true ->
        validate_required_schema_string!(type, "output id", Map.get(spec, "id"))
    end
  end

  defp validate_output_spec!(type, spec) do
    raise ArgumentError,
          "step type #{type.id} output handle declaration must be a map, got: #{inspect(spec)}"
  end

  defp validate_unique_handle_ids!(type, label, handles) do
    ids = Enum.map(handles, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] ->
        :ok

      duplicates ->
        raise ArgumentError,
              "step type #{type.id} has duplicate #{label} handle ids: #{inspect(duplicates)}"
    end
  end

  defp validate_no_duplicate_static_outputs!(ids, type) do
    case ids -- Enum.uniq(ids) do
      [] ->
        :ok

      duplicates ->
        raise ArgumentError,
              "step type #{type.id} has duplicate output handle ids: #{inspect(duplicates)}"
    end
  end

  defp validate_required_schema_string!(_type, _label, value)
       when is_binary(value) and value != "",
       do: :ok

  defp validate_required_schema_string!(type, label, value) do
    raise ArgumentError,
          "step type #{type.id} #{label} must be a non-empty string, got: #{inspect(value)}"
  end

  defp normalize_kind(value) when value in [:flow, "flow"], do: :flow
  defp normalize_kind(value) when value in [:dependency, "dependency"], do: :dependency

  defp normalize_kind(value) do
    raise ArgumentError,
          "connection handle kind must be flow or dependency, got: #{inspect(value)}"
  end

  defp normalize_cardinality(value) when value in [:one, "one"], do: :one
  defp normalize_cardinality(value) when value in [:many, "many"], do: :many

  defp normalize_cardinality(value) do
    raise ArgumentError,
          "connection handle cardinality must be one or many, got: #{inspect(value)}"
  end

  defp normalize_accepts(value) when is_map(value) do
    %{provides: normalize_provides(Map.get(value, "provides", Map.get(value, :provides, [])))}
  end

  defp normalize_accepts(nil), do: %{provides: []}

  defp normalize_accepts(value) do
    raise ArgumentError, "connection handle accepts must be a map, got: #{inspect(value)}"
  end

  defp normalize_provides(nil), do: []

  defp normalize_provides(values) when is_list(values) do
    Enum.map(values, fn
      value when is_binary(value) and value != "" ->
        value

      value ->
        raise ArgumentError,
              "connection handle provides must contain only non-empty strings, got: #{inspect(value)}"
    end)
  end

  defp normalize_provides(value) do
    raise ArgumentError, "connection handle provides must be a list, got: #{inspect(value)}"
  end
end
