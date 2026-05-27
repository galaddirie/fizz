defmodule Fizz.Integrations.Microsoft.Teams.Actions.SendMessage do
  @moduledoc """
  Posts a message to a Microsoft Teams channel or chat.
  """

  use Fizz.Integrations.StepDefinition,
    id: "teams_send_message",
    name: "Microsoft Teams — Send Message",
    category: "Communication",
    description: "Post a message to a Microsoft Teams channel or group chat",
    icon: "/images/microsoft_teams.svg",
    kind: :action,
    provider: "microsoft_oauth",
    integration: "teams"

  use Fizz.Integrations.PlaceholderStep

  alias Fizz.Integrations.Providers.MicrosoftOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(MicrosoftOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Microsoft Account",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("team_id", label: "Team ID", required?: true),
    Fields.string("channel_id", label: "Channel ID", required?: true),
    Fields.string("message",
      label: "Message",
      required?: true,
      description: "Supports HTML or plain text"
    )
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "message_id" => %{"type" => "string"},
      "created_at" => %{"type" => "string"}
    }
  }
end
