defmodule Fizz.Integrations.Library.Microsoft.Teams do
  @moduledoc """
  Microsoft Teams product integration catalog entry.
  """

  use Fizz.Integrations.Contracts.StaticIntegration,
    id: "teams",
    display_name: "Microsoft Teams",
    provider_id: "microsoft_oauth",
    actions: ["teams_send_message"],
    step_modules: [
      Fizz.Integrations.Library.Microsoft.Teams.Triggers.NewMessage,
      Fizz.Integrations.Library.Microsoft.Teams.Actions.SendMessage
    ]
end
