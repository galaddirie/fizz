defmodule Fizz.Integrations.OpenAI.Actions.ImageGeneration do
  @moduledoc """
  Generates an image using OpenAI DALL-E (subnode for AI Agent or standalone action).
  """

  use Fizz.Integrations.StepDefinition,
    id: "openai_image_generation",
    name: "OpenAI — Image Generation",
    category: "AI",
    description: "Generate an image with DALL-E 3 from a text prompt",
    icon: "/images/openai.svg",
    kind: :action,
    provider: "openai_api_key",
    integration: "openai"

  use Fizz.Integrations.PlaceholderStep

  alias Fizz.Integrations.Providers.OpenAIApiKey
  alias Fizz.Fields

  @credential_field Fields.credential(OpenAIApiKey.provider_id(), :api_key,
                      key: "credential_ref",
                      label: "OpenAI Credential",
                      description: "OpenAI credential. Bound at run time per user.",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("prompt",
      label: "Prompt",
      required?: true,
      description: "Description of the image to generate"
    ),
    Fields.select("model",
      label: "Model",
      default: "dall-e-3",
      options: Fields.options(~w(dall-e-3 dall-e-2))
    ),
    Fields.select("size",
      label: "Size",
      default: "1024x1024",
      options: Fields.options(~w(1024x1024 1792x1024 1024x1792))
    ),
    Fields.select("quality",
      label: "Quality",
      default: "standard",
      options: Fields.options(~w(standard hd))
    ),
    Fields.number("n", label: "Number of Images", default: 1)
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "image_url" => %{"type" => "string", "description" => "URL to the generated image"},
      "revised_prompt" => %{
        "type" => "string",
        "description" => "Prompt used after safety revision"
      },
      "images" => %{"type" => "array", "description" => "All generated image URLs"}
    }
  }
end
