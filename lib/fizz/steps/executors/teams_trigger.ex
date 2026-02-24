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

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "credential_ref" => %{
        "type" => "object",
        "title" => "Microsoft Account"
      },
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
