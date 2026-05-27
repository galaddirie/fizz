defmodule Fizz.Integrations.Fizz.Builtins.AIToolHttp do
  @moduledoc """
  Produces an HTTP tool descriptor consumable by AI agent steps.
  """

  use Fizz.Integrations.StepDefinition,
    id: "ai_tool_http",
    name: "AI Tool: HTTP",
    category: "AI",
    description: "Declare an HTTP tool for AI agent execution",
    icon: "hero-globe-alt",
    kind: :transform,
    integration: "fizz",
    role: :subnode

  @behaviour Fizz.Workflows.StepExecutor

  alias Fizz.Fields

  @fields [
    Fields.string("name", label: "Tool Name", required?: true, default: "http_tool"),
    Fields.string("description", label: "Description", default: "HTTP tool"),
    Fields.select("method",
      label: "Method",
      default: "GET",
      options: Fields.options(~w(GET POST PUT PATCH DELETE))
    ),
    Fields.string("url", label: "URL", required?: true),
    Fields.json("headers", label: "Headers", default: %{})
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "type" => %{"type" => "string"},
      "name" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "request" => %{"type" => "object"}
    }
  }

  @impl true
  def execute(config, _input, _ctx) do
    {:ok,
     %{
       "type" => "http",
       "name" => Map.get(config, "name"),
       "description" => Map.get(config, "description", ""),
       "request" => %{
         "method" => Map.get(config, "method", "GET"),
         "url" => Map.get(config, "url"),
         "headers" => Map.get(config, "headers", %{})
       }
     }}
  end

  @impl true
  def validate_config(config) do
    errors = []

    errors =
      case Map.get(config, "name") do
        name when is_binary(name) ->
          if String.trim(name) == "" do
            [{:name, "is required"} | errors]
          else
            errors
          end

        _ ->
          [{:name, "is required"} | errors]
      end

    errors =
      case Map.get(config, "url") do
        url when is_binary(url) ->
          if String.trim(url) == "" do
            [{:url, "is required"} | errors]
          else
            errors
          end

        _ ->
          [{:url, "is required"} | errors]
      end

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end
end
