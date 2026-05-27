defmodule Fizz.Integrations.Library.OpenAI do
  @moduledoc """
  OpenAI product integration catalog entry.
  """

  use Fizz.Integrations.Contracts.StaticIntegration,
    id: "openai",
    display_name: "OpenAI",
    provider_id: "openai_api_key",
    actions: ["openai_image_generation"],
    step_modules: [
      Fizz.Integrations.Library.OpenAI.Nodes.Model,
      Fizz.Integrations.Library.OpenAI.Actions.ImageGeneration
    ]
end
