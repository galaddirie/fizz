defmodule Fizz.Integrations.Library.Microsoft.Teams.Triggers.NewMessage do
  @moduledoc """
  Trigger that fires when a new message is posted to a Microsoft Teams channel.
  """

  use Fizz.Integrations.Steps.Definition,
    id: "teams_trigger",
    name: "Microsoft Teams — New Message",
    category: "Triggers",
    description: "Fires when a new message is posted in a Microsoft Teams channel",
    icon: "/images/microsoft_teams.svg",
    kind: :trigger,
    provider: "microsoft_oauth",
    integration: "teams"

  use Fizz.Integrations.Steps.Placeholder

  alias Fizz.Integrations.Auth.Providers.MicrosoftOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(MicrosoftOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Microsoft Account",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("team_id", label: "Team ID"),
    Fields.string("channel_id", label: "Channel ID")
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "message_id" => %{"type" => "string"},
      "from" => %{"type" => "string"},
      "text" => %{"type" => "string"},
      "created_at" => %{"type" => "string"}
    }
  }
end
