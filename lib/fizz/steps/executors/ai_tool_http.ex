defmodule Fizz.Steps.Executors.AIToolHttp do
  @moduledoc """
  Produces an HTTP tool descriptor consumable by AI agent steps.
  """

  use Fizz.Steps.Definition,
    id: "ai_tool_http",
    name: "AI Tool: HTTP",
    category: "AI",
    description: "Declare an HTTP tool for AI agent execution",
    icon: "hero-globe-alt",
    kind: :transform,
    role: :subnode

  @behaviour Fizz.Steps.Executors.Behaviour

  @default_config %{
    "name" => "http_tool",
    "description" => "HTTP tool",
    "method" => "GET",
    "url" => "",
    "headers" => %{}
  }

  @config_schema %{
    "type" => "object",
    "required" => ["name", "url"],
    "properties" => %{
      "name" => %{"type" => "string", "title" => "Tool Name"},
      "description" => %{"type" => "string", "title" => "Description"},
      "method" => %{
        "type" => "string",
        "title" => "Method",
        "enum" => ["GET", "POST", "PUT", "PATCH", "DELETE"],
        "default" => "GET"
      },
      "url" => %{"type" => "string", "title" => "URL"},
      "headers" => %{"title" => "Headers"}
    }
  }

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
  def default_config, do: @default_config

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
