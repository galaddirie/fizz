defmodule Fizz.Integrations.Library.Google.Gmail do
  @moduledoc """
  Gmail product integration catalog entry.
  """

  use Fizz.Integrations.Contracts.StaticIntegration,
    id: "gmail",
    display_name: "Gmail",
    provider_id: "google_oauth",
    actions: ["gmail_send_email", "gmail_reply_email"],
    step_modules: [
      Fizz.Integrations.Library.Google.Gmail.Triggers.NewEmail,
      Fizz.Integrations.Library.Google.Gmail.Actions.SendEmail,
      Fizz.Integrations.Library.Google.Gmail.Actions.ReplyEmail
    ]
end
