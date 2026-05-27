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

  @behaviour Fizz.Steps.Executor

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

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Microsoft Graph teams chatMessages.create
    {:ok, %{}}
  end
end
