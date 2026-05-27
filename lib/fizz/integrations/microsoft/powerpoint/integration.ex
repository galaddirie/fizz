defmodule Fizz.Integrations.Microsoft.PowerPoint do
  @moduledoc """
  Microsoft PowerPoint product integration catalog entry.
  """

  use Fizz.Integrations.StaticIntegration,
    id: "powerpoint",
    display_name: "PowerPoint",
    provider_id: "microsoft_oauth",
    actions: ["powerpoint_create_presentation"],
    step_modules: [
      Fizz.Integrations.Microsoft.PowerPoint.Actions.CreatePresentation
    ]
end
