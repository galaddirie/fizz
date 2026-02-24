defmodule Fizz.Steps.Executors.OutlookTrigger do
  @moduledoc """
  Trigger that fires when a new email arrives in Microsoft Outlook.
  """

  use Fizz.Steps.Definition,
    id: "outlook_trigger",
    name: "Outlook — New Email",
    category: "Triggers",
    description: "Fires when a new email arrives in a Microsoft Outlook inbox",
    icon: "/images/microsoft_outlook.svg",
    kind: :trigger

  @behaviour Fizz.Steps.Executors.Behaviour

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "credential_ref" => %{
        "type" => "object",
        "title" => "Microsoft Account"
      },
      "folder" => %{
        "type" => "string",
        "title" => "Folder",
        "default" => "Inbox"
      },
      "from_filter" => %{
        "type" => "string",
        "title" => "From Filter"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "message_id" => %{"type" => "string"},
      "from" => %{"type" => "string"},
      "to" => %{"type" => "string"},
      "subject" => %{"type" => "string"},
      "body_text" => %{"type" => "string"},
      "body_html" => %{"type" => "string"},
      "received_at" => %{"type" => "string"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Microsoft Graph mail subscription / polling
    {:ok, %{}}
  end
end
