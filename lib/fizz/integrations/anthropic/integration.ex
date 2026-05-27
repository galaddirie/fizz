defmodule Fizz.Integrations.Anthropic do
  @moduledoc """
  Anthropic product integration catalog entry.
  """

  use Fizz.Integrations.StaticIntegration,
    id: "anthropic",
    display_name: "Anthropic",
    provider_id: "anthropic_api_key",
    actions: ["anthropic_vision_analysis"],
    step_modules: [
      Fizz.Integrations.Anthropic.Nodes.Model,
      Fizz.Integrations.Anthropic.Actions.VisionAnalysis
    ]
end
