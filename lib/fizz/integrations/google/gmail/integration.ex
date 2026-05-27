defmodule Fizz.Integrations.Google.Gmail do
  @moduledoc """
  Gmail product integration catalog entry.
  """

  use Fizz.Integrations.StaticIntegration,
    id: "gmail",
    display_name: "Gmail",
    provider_id: "google_oauth",
    actions: ["gmail_send_email", "gmail_reply_email"],
    step_modules: [
      Fizz.Integrations.Google.Gmail.Triggers.NewEmail,
      Fizz.Integrations.Google.Gmail.Actions.SendEmail,
      Fizz.Integrations.Google.Gmail.Actions.ReplyEmail
    ]
end
