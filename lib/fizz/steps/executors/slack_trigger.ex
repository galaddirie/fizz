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

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "credential_ref" => %{
        "type" => "object",
        "title" => "Slack project",
        "description" => "Slack OAuth credential"
      },
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
