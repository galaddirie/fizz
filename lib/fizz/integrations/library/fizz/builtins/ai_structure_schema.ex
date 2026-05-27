defmodule Fizz.Integrations.Library.Fizz.Builtins.AIStructureSchema do
  @moduledoc """
  Produces a structured output schema for AI agent steps.
  """

  use Fizz.Integrations.Steps.Definition,
    id: "ai_structure_schema",
    name: "Structure Schema",
    category: "AI",
    description: "Declare the structured response schema expected from an AI agent",
    icon: "hero-code-bracket-square",
    kind: :transform,
    integration: "fizz",
    role: :subnode

  @behaviour Fizz.Workflows.StepExecutor

  @default_json_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{}
  }

  alias Fizz.Fields

  @fields [
    Fields.string("name",
      label: "Schema Name",
      default: "structured_response",
      description: "Provider-safe name for the structured response"
    ),
    Fields.json("json_schema",
      label: "Structure Schema",
      format: "json",
      required?: true,
      default: @default_json_schema,
      description: "JSON Schema describing the expected agent response"
    ),
    Fields.boolean("strict",
      label: "Strict Mode",
      default: true,
      description: "Ask the provider to follow the schema strictly when supported"
    )
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "name" => %{"type" => "string"},
      "json_schema" => %{"type" => "object"},
      "strict" => %{"type" => "boolean"},
      "response_format" => %{"type" => "object", "description" => "Provider response format hint"}
    }
  }

  @impl true
  def execute(config, _input, _ctx) do
    with {:ok, json_schema} <- normalize_json_schema(config) do
      name = normalize_name(Map.get(config, "name", "structured_response"))
      strict = normalize_strict(Map.get(config, "strict", true))

      {:ok,
       %{
         "name" => name,
         "json_schema" => json_schema,
         "strict" => strict,
         "response_format" => response_format(name, json_schema, strict)
       }}
    end
  end

  @impl true
  def validate_config(config) do
    errors = []
    errors = validate_name(config, errors)
    errors = validate_json_schema(config, errors)
    errors = validate_strict(config, errors)

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp normalize_json_schema(config) do
    case Map.get(config, "json_schema") || Map.get(config, :json_schema) do
      schema when is_map(schema) and map_size(schema) > 0 ->
        {:ok, unwrap_pasted_schema(schema)}

      _ ->
        {:error, {:invalid_config, :json_schema}}
    end
  end

  defp unwrap_pasted_schema(%{"json_schema" => json_schema} = schema)
       when is_map(json_schema) and map_size(json_schema) > 0 do
    if schema_wrapper?(schema, json_schema) do
      unwrap_pasted_schema(json_schema)
    else
      schema
    end
  end

  defp unwrap_pasted_schema(schema), do: schema

  defp schema_wrapper?(schema, json_schema) do
    not Map.has_key?(schema, "type") and Map.has_key?(json_schema, "type") and
      Enum.any?(["name", "strict"], &Map.has_key?(schema, &1))
  end

  defp normalize_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> "structured_response"
      trimmed_name -> trimmed_name
    end
  end

  defp normalize_name(_name), do: "structured_response"

  defp normalize_strict(strict) when strict in [true, false], do: strict
  defp normalize_strict(_strict), do: true

  defp response_format(name, json_schema, strict) do
    %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => name,
        "schema" => json_schema,
        "strict" => strict
      }
    }
  end

  defp validate_name(config, errors) do
    case Map.get(config, "name", "structured_response") do
      name when is_binary(name) ->
        if String.trim(name) == "" do
          [{:name, "is required"} | errors]
        else
          errors
        end

      _ ->
        [{:name, "must be a string"} | errors]
    end
  end

  defp validate_json_schema(config, errors) do
    case normalize_json_schema(config) do
      {:ok, _schema} -> errors
      _ -> [{:json_schema, "is required"} | errors]
    end
  end

  defp validate_strict(config, errors) do
    case Map.get(config, "strict", true) do
      strict when strict in [true, false] -> errors
      _ -> [{:strict, "must be a boolean"} | errors]
    end
  end
end
