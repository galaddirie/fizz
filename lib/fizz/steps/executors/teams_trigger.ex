defmodule Fizz.Steps.Executors.TeamsTrigger do
  @moduledoc """
  Trigger that fires when a new message is posted to a Microsoft Teams channel.
  """

  use Fizz.Steps.Definition,
    id: "teams_trigger",
    name: "Microsoft Teams — New Message",
    category: "Triggers",
    description: "Fires when a new message is posted in a Microsoft Teams channel",
    icon: "/images/microsoft_teams.svg",
    kind: :trigger

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Providers.MicrosoftOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(MicrosoftOAuth.provider_id(), :oauth,
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
        Fields.to_schema_property(@credential_field, label: "Microsoft Account"),
      "team_id" => %{
        "type" => "string",
        "title" => "Team ID"
      },
      "channel_id" => %{
        "type" => "string",
        "title" => "Channel ID"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "message_id" => %{"type" => "string"},
      "from" => %{"type" => "string"},
      "text" => %{"type" => "string"},
      "created_at" => %{"type" => "string"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Microsoft Graph change notifications subscription
    {:ok, %{}}
  end
end
