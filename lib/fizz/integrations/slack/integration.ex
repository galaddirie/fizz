defmodule Fizz.Integrations.Slack do
  @moduledoc """
  Slack product integration catalog entry.
  """

  use Fizz.Integrations.StaticIntegration,
    id: "slack",
    display_name: "Slack",
    provider_id: "slack_oauth",
    actions: ["slack_send_message", "slack_create_channel"],
    step_modules: [
      Fizz.Integrations.Slack.Triggers.NewMessage,
      Fizz.Integrations.Slack.Actions.SendMessage,
      Fizz.Integrations.Slack.Actions.CreateChannel
    ]
end
