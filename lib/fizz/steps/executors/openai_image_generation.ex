defmodule Fizz.Steps.Executors.OpenAIImageGeneration do
  @moduledoc """
  Generates an image using OpenAI DALL-E (subnode for AI Agent or standalone action).
  """

  use Fizz.Steps.Definition,
    id: "openai_image_generation",
    name: "OpenAI — Image Generation",
    category: "AI",
    description: "Generate an image with DALL-E 3 from a text prompt",
    icon: "/images/openai.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  @config_schema %{
    "type" => "object",
    "required" => ["prompt"],
    "properties" => %{
      "credential_ref" => %{
        "type" => "object",
        "title" => "OpenAI Credential"
      },
      "prompt" => %{
        "type" => "string",
        "title" => "Prompt",
        "description" => "Description of the image to generate"
      },
      "model" => %{
        "type" => "string",
        "title" => "Model",
        "enum" => ["dall-e-3", "dall-e-2"],
        "default" => "dall-e-3"
      },
      "size" => %{
        "type" => "string",
        "title" => "Size",
        "enum" => ["1024x1024", "1792x1024", "1024x1792"],
        "default" => "1024x1024"
      },
      "quality" => %{
        "type" => "string",
        "title" => "Quality",
        "enum" => ["standard", "hd"],
        "default" => "standard"
      },
      "n" => %{
        "type" => "integer",
        "title" => "Number of Images",
        "default" => 1
      }
    }
  }

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

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement OpenAI images.generate call
    {:ok, %{}}
  end
end
