defmodule Fizz.Integrations.Library.Microsoft.Outlook do
  @moduledoc """
  Microsoft Outlook product integration catalog entry.
  """

  use Fizz.Integrations.Contracts.StaticIntegration,
    id: "outlook",
    display_name: "Outlook",
    provider_id: "microsoft_oauth",
    actions: ["outlook_send_email"],
    step_modules: [
      Fizz.Integrations.Library.Microsoft.Outlook.Triggers.NewEmail,
      Fizz.Integrations.Library.Microsoft.Outlook.Actions.SendEmail
    ]
end
