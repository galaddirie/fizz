defmodule Fizz.Steps.Executors.TeamsSendMessage do
  @moduledoc """
  Posts a message to a Microsoft Teams channel or chat.
  """

  use Fizz.Steps.Definition,
    id: "teams_send_message",
    name: "Microsoft Teams — Send Message",
    category: "Communication",
    description: "Post a message to a Microsoft Teams channel or group chat",
    icon: "/images/microsoft_teams.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Providers.MicrosoftOAuth
  alias Fizz.Slots.CredentialSlot

  @credential_slot CredentialSlot.oauth(MicrosoftOAuth.provider_id())

  @default_config %{
    "credential_ref" => CredentialSlot.declaration(@credential_slot)
  }

  @config_schema %{
    "type" => "object",
    "required" => ["team_id", "channel_id", "message"],
    "properties" => %{
      "credential_ref" => CredentialSlot.schema(@credential_slot, title: "Microsoft Account"),
      "team_id" => %{
        "type" => "string",
        "title" => "Team ID"
      },
      "channel_id" => %{
        "type" => "string",
        "title" => "Channel ID"
      },
      "message" => %{
        "type" => "string",
        "title" => "Message",
        "description" => "Supports HTML or plain text"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "message_id" => %{"type" => "string"},
      "created_at" => %{"type" => "string"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Microsoft Graph teams chatMessages.create
    {:ok, %{}}
  end
end
