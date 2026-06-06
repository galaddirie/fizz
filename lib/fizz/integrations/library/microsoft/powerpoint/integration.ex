defmodule Fizz.Integrations.Library.Microsoft.PowerPoint do
  @moduledoc """
  Microsoft PowerPoint product integration catalog entry.
  """

  use Fizz.Integrations.Contracts.StaticIntegration,
    id: "powerpoint",
    display_name: "PowerPoint",
    provider_id: "microsoft_oauth",
    actions: ["powerpoint_create_presentation"],
    step_modules: [
      Fizz.Integrations.Library.Microsoft.PowerPoint.Actions.CreatePresentation
    ]
end
