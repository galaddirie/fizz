defmodule Fizz.Integrations.Slack.Actions.SendMessage do
  @moduledoc """
  Posts a message to a Slack channel or DM.
  """

  use Fizz.Integrations.StepDefinition,
    id: "slack_send_message",
    name: "Slack — Send Message",
    category: "Communication",
    description: "Post a message to a Slack channel, DM, or thread",
    icon: "/images/slack.svg",
    kind: :action,
    provider: "slack_oauth",
    integration: "slack"

  use Fizz.Integrations.PlaceholderStep

  alias Fizz.Integrations.Providers.SlackOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(SlackOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Slack Workspace",
                      description: "Slack workspace. Bound at run time per user.",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("channel_id",
      label: "Channel",
      required?: true,
      description: "Channel ID, user ID, or email"
    ),
    Fields.string("text",
      label: "Message",
      required?: true,
      description: "Message text (supports Slack markdown)"
    ),
    Fields.string("thread_ts",
      label: "Reply Thread Timestamp",
      description: "If set, reply in this thread"
    ),
    Fields.string("username", label: "Bot Username Override")
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "ts" => %{"type" => "string", "description" => "Message timestamp"},
      "channel" => %{"type" => "string"},
      "ok" => %{"type" => "boolean"}
    }
  }
end
