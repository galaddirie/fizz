defmodule Fizz.Integrations.OpenAI do
  @moduledoc """
  OpenAI product integration catalog entry.
  """

  use Fizz.Integrations.StaticIntegration,
    id: "openai",
    display_name: "OpenAI",
    provider_id: "openai_api_key",
    actions: ["openai_image_generation"],
    step_modules: [
      Fizz.Integrations.OpenAI.Nodes.Model,
      Fizz.Integrations.OpenAI.Actions.ImageGeneration
    ]
end
