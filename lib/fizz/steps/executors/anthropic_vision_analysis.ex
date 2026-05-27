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

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Providers.AnthropicApiKey
  alias Fizz.Fields

  @credential_field Fields.credential(AnthropicApiKey.provider_id(), :api_key,
                      key: "credential_ref",
                      requirement_key: "auth"
                    )

  @default_config %{
    "model" => "claude-3-5-sonnet-latest",
    "credential_ref" => Fields.default_value(@credential_field)
  }

  @config_schema %{
    "type" => "object",
    "required" => ["image_url", "prompt"],
    "properties" => %{
      "credential_ref" =>
        Fields.to_schema_property(@credential_field,
          label: "Anthropic Credential",
          description: "Anthropic credential. Bound at run time per user."
        ),
      "model" => %{
        "type" => "string",
        "title" => "Model",
        "default" => "claude-3-5-sonnet-latest"
      },
      "image_url" => %{
        "type" => "string",
        "title" => "Image URL",
        "description" => "URL or base64 data URI of the image to analyze"
      },
      "prompt" => %{
        "type" => "string",
        "title" => "Analysis Prompt",
        "description" => "What do you want Claude to do with the image?"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "analysis" => %{"type" => "string", "description" => "Claude's response text"},
      "model" => %{"type" => "string"},
      "usage" => %{"type" => "object"}
    }
  }

  @impl true
  def default_config, do: @default_config

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Anthropic vision message with image content
    {:ok, %{}}
  end
end
