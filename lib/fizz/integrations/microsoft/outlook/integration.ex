defmodule Fizz.Integrations.Microsoft.Outlook do
  @moduledoc """
  Microsoft Outlook product integration catalog entry.
  """

  use Fizz.Integrations.StaticIntegration,
    id: "outlook",
    display_name: "Outlook",
    provider_id: "microsoft_oauth",
    actions: ["outlook_send_email"],
    step_modules: [
      Fizz.Integrations.Microsoft.Outlook.Triggers.NewEmail,
      Fizz.Integrations.Microsoft.Outlook.Actions.SendEmail
    ]
end
