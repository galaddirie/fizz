defmodule Fizz.Steps.Executors.AnthropicVisionAnalysis do
  @moduledoc """
  Analyzes an image using Anthropic Claude's vision capabilities.
  """

  use Fizz.Steps.Definition,
    id: "anthropic_vision_analysis",
    name: "Anthropic — Vision Analysis",
    category: "AI",
    description: "Analyze or describe an image using Claude's vision API",
    icon: "/images/anthropic.svg",
    kind: :action

  @behaviour Fizz.Steps.Executor

  alias Fizz.Integrations.Providers.AnthropicApiKey
  alias Fizz.Fields

  @credential_field Fields.credential(AnthropicApiKey.provider_id(), :api_key,
                      key: "credential_ref",
                      label: "Anthropic Credential",
                      description: "Anthropic credential. Bound at run time per user.",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("model", label: "Model", default: "claude-3-5-sonnet-latest"),
    Fields.string("image_url",
      label: "Image URL",
      required?: true,
      description: "URL or base64 data URI of the image to analyze"
    ),
    Fields.string("prompt",
      label: "Analysis Prompt",
      required?: true,
      description: "What do you want Claude to do with the image?"
    )
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "analysis" => %{"type" => "string", "description" => "Claude's response text"},
      "model" => %{"type" => "string"},
      "usage" => %{"type" => "object"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Anthropic vision message with image content
    {:ok, %{}}
  end
end
