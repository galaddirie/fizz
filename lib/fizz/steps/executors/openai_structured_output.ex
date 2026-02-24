defmodule Fizz.Steps.Executors.OpenAIStructuredOutput do
  @moduledoc """
  Subnode that configures OpenAI structured / JSON output for an AI Agent.
  """

  use Fizz.Steps.Definition,
    id: "openai_structured_output",
    name: "OpenAI — Structured Output",
    category: "AI",
    description:
      "Configure JSON schema-constrained structured output for an OpenAI model (subnode)",
    icon: "/images/openai.svg",
    kind: :transform,
    role: :subnode

  @behaviour Fizz.Steps.Executors.Behaviour

  @config_schema %{
    "type" => "object",
    "required" => ["json_schema"],
    "properties" => %{
      "json_schema" => %{
        "type" => "object",
        "title" => "Output JSON Schema",
        "description" => "JSON Schema defining the expected structured response"
      },
      "strict" => %{
        "type" => "boolean",
        "title" => "Strict Mode",
        "default" => true,
        "description" => "Enforce strict schema adherence"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "response_format" => %{"type" => "object", "description" => "OpenAI response_format config"},
      "json_schema" => %{"type" => "object"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Build response_format payload for OpenAI structured output
    {:ok, %{}}
  end
end
