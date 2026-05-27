defmodule Fizz.Integrations.Library.Anthropic do
  @moduledoc """
  Anthropic product integration catalog entry.
  """

  use Fizz.Integrations.Contracts.StaticIntegration,
    id: "anthropic",
    display_name: "Anthropic",
    provider_id: "anthropic_api_key",
    actions: ["anthropic_vision_analysis"],
    step_modules: [
      Fizz.Integrations.Library.Anthropic.Nodes.Model,
      Fizz.Integrations.Library.Anthropic.Actions.VisionAnalysis
    ]
end
