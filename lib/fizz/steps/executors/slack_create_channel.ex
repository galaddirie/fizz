defmodule Fizz.Steps.Executors.SlackCreateChannel do
  @moduledoc """
  Creates a new Slack channel.
  """

  use Fizz.Steps.Definition,
    id: "slack_create_channel",
    name: "Slack — Create Channel",
    category: "Communication",
    description: "Create a new public or private Slack channel",
    icon: "/images/slack.svg",
    kind: :action

  @behaviour Fizz.Steps.Executor

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
    Fields.string("channel_name",
      label: "Channel Name",
      required?: true,
      description: "Lowercase, hyphen-separated (e.g. project-alpha)"
    ),
    Fields.boolean("is_private", label: "Private Channel", default: false)
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "channel_id" => %{"type" => "string"},
      "channel_name" => %{"type" => "string"},
      "is_private" => %{"type" => "boolean"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Slack conversations.create
    {:ok, %{}}
  end
end
