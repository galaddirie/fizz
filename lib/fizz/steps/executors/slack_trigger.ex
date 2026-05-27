defmodule Fizz.Steps.Executors.SlackTrigger do
  @moduledoc """
  Trigger that fires when a new message is posted to a Slack channel.
  """

  use Fizz.Steps.Definition,
    id: "slack_trigger",
    name: "Slack — New Message",
    category: "Triggers",
    description: "Fires when a new message is posted in a Slack channel or DM",
    icon: "/images/slack.svg",
    kind: :trigger

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Providers.SlackOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(SlackOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      requirement_key: "auth"
                    )

  @default_config %{
    "credential_ref" => Fields.default_value(@credential_field)
  }

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "credential_ref" =>
        Fields.to_schema_property(@credential_field,
          label: "Slack Workspace",
          description: "Slack workspace. Bound at run time per user."
        ),
      "channel_id" => %{
        "type" => "string",
        "title" => "Channel",
        "description" => "Channel ID to watch (e.g. C0123456)"
      },
      "bot_mention_only" => %{
        "type" => "boolean",
        "title" => "Only when bot is mentioned",
        "default" => false
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "message_id" => %{"type" => "string"},
      "channel_id" => %{"type" => "string"},
      "user_id" => %{"type" => "string"},
      "text" => %{"type" => "string", "description" => "Message text"},
      "thread_ts" => %{"type" => "string", "description" => "Thread timestamp"},
      "timestamp" => %{"type" => "string"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Slack Events API webhook trigger
    {:ok, %{}}
  end
end
