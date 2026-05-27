defmodule Fizz.Integrations.Library.Slack do
  @moduledoc """
  Slack product integration catalog entry.
  """

  use Fizz.Integrations.Contracts.StaticIntegration,
    id: "slack",
    display_name: "Slack",
    provider_id: "slack_oauth",
    actions: ["slack_send_message", "slack_create_channel"],
    step_modules: [
      Fizz.Integrations.Library.Slack.Triggers.NewMessage,
      Fizz.Integrations.Library.Slack.Actions.SendMessage,
      Fizz.Integrations.Library.Slack.Actions.CreateChannel
    ]
end
