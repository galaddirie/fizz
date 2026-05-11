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

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Providers.SlackOAuth
  alias Fizz.Slots.CredentialSlot

  @credential_slot CredentialSlot.oauth(SlackOAuth.provider_id())

  @default_config %{
    "credential_ref" => CredentialSlot.declaration(@credential_slot)
  }

  @config_schema %{
    "type" => "object",
    "required" => ["channel_name"],
    "properties" => %{
      "credential_ref" =>
        CredentialSlot.schema(@credential_slot,
          title: "Slack Workspace",
          description: "Slack workspace. Bound at run time per user."
        ),
      "channel_name" => %{
        "type" => "string",
        "title" => "Channel Name",
        "description" => "Lowercase, hyphen-separated (e.g. project-alpha)"
      },
      "is_private" => %{
        "type" => "boolean",
        "title" => "Private Channel",
        "default" => false
      }
    }
  }

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
