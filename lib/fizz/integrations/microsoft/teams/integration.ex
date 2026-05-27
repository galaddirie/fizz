defmodule Fizz.Integrations.Microsoft.Teams do
  @moduledoc """
  Microsoft Teams product integration catalog entry.
  """

  use Fizz.Integrations.StaticIntegration,
    id: "teams",
    display_name: "Microsoft Teams",
    provider_id: "microsoft_oauth",
    actions: ["teams_send_message"],
    step_modules: [
      Fizz.Integrations.Microsoft.Teams.Triggers.NewMessage,
      Fizz.Integrations.Microsoft.Teams.Actions.SendMessage
    ]
end
