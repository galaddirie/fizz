defmodule Fizz.Steps.Executors.SlackSendMessage do
  @moduledoc """
  Posts a message to a Slack channel or DM.
  """

  use Fizz.Steps.Definition,
    id: "slack_send_message",
    name: "Slack — Send Message",
    category: "Communication",
    description: "Post a message to a Slack channel, DM, or thread",
    icon: "/images/slack.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  @config_schema %{
    "type" => "object",
    "required" => ["channel_id", "text"],
    "properties" => %{
      "credential_ref" => %{
        "type" => "object",
        "title" => "Slack Workspace"
      },
      "channel_id" => %{
        "type" => "string",
        "title" => "Channel",
        "description" => "Channel ID, user ID, or email"
      },
      "text" => %{
        "type" => "string",
        "title" => "Message",
        "description" => "Message text (supports Slack markdown)"
      },
      "thread_ts" => %{
        "type" => "string",
        "title" => "Reply Thread Timestamp",
        "description" => "If set, reply in this thread"
      },
      "username" => %{
        "type" => "string",
        "title" => "Bot Username Override"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "ts" => %{"type" => "string", "description" => "Message timestamp"},
      "channel" => %{"type" => "string"},
      "ok" => %{"type" => "boolean"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Slack chat.postMessage API call
    {:ok, %{}}
  end
end
