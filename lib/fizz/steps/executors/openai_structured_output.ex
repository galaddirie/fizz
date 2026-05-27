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

  @behaviour Fizz.Steps.Executor

  alias Fizz.Fields

  @fields [
    Fields.json("json_schema",
      label: "Output JSON Schema",
      required?: true,
      description: "JSON Schema defining the expected structured response"
    ),
    Fields.boolean("strict",
      label: "Strict Mode",
      default: true,
      description: "Enforce strict schema adherence"
    )
  ]

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
