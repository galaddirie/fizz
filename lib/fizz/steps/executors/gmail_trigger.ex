defmodule Fizz.Steps.Executors.GmailTrigger do
  @moduledoc """
  Trigger that fires when a new email is received in Gmail.
  """

  use Fizz.Steps.Definition,
    id: "gmail_trigger",
    name: "Gmail — New Email",
    category: "Triggers",
    description: "Fires when a new email arrives in a Gmail inbox",
    icon: "/images/gmail.svg",
    kind: :trigger

  @behaviour Fizz.Steps.Executors.Behaviour

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "credential_ref" => %{
        "type" => "object",
        "title" => "Gmail Account",
        "description" => "Google account to watch for new emails"
      },
      "label_filter" => %{
        "type" => "string",
        "title" => "Label Filter",
        "description" => "Only trigger for emails with this label (e.g. INBOX)"
      },
      "from_filter" => %{
        "type" => "string",
        "title" => "From Filter",
        "description" => "Only trigger for emails from this address"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "message_id" => %{"type" => "string", "description" => "Gmail message ID"},
      "thread_id" => %{"type" => "string"},
      "from" => %{"type" => "string", "description" => "Sender address"},
      "to" => %{"type" => "string"},
      "subject" => %{"type" => "string"},
      "body_text" => %{"type" => "string", "description" => "Plain-text body"},
      "body_html" => %{"type" => "string", "description" => "HTML body"},
      "received_at" => %{"type" => "string", "description" => "ISO 8601 timestamp"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Gmail webhook / polling trigger
    {:ok, %{}}
  end
end
