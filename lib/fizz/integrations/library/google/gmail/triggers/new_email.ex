defmodule Fizz.Integrations.Library.Google.Gmail.Triggers.NewEmail do
  @moduledoc """
  Trigger that fires when a new email is received in Gmail.
  """

  use Fizz.Integrations.Steps.Definition,
    id: "gmail_trigger",
    name: "Gmail — New Email",
    category: "Triggers",
    description: "Fires when a new email arrives in a Gmail inbox",
    icon: "/images/gmail.svg",
    kind: :trigger,
    provider: "google_oauth",
    integration: "gmail"

  use Fizz.Integrations.Steps.Placeholder

  alias Fizz.Integrations.Auth.Providers.GoogleOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(GoogleOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Gmail Account",
                      description: "Google account. Bound at run time per user.",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("label_filter",
      label: "Label Filter",
      description: "Only trigger for emails with this label (e.g. INBOX)"
    ),
    Fields.string("from_filter",
      label: "From Filter",
      description: "Only trigger for emails from this address"
    )
  ]

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
end
