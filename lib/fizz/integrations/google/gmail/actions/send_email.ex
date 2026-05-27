defmodule Fizz.Integrations.Google.Gmail.Actions.SendEmail do
  @moduledoc """
  Sends an email via Gmail / Google project.
  """

  use Fizz.Integrations.StepDefinition,
    id: "gmail_send_email",
    name: "Gmail — Send Email",
    category: "Email",
    description: "Send an email via Gmail or Google project",
    icon: "/images/gmail.svg",
    kind: :action,
    provider: "google_oauth",
    integration: "gmail"

  use Fizz.Integrations.PlaceholderStep

  alias Fizz.Integrations.Providers.GoogleOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(GoogleOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Gmail Account",
                      description: "Google account. Bound at run time per user.",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("to",
      label: "To",
      required?: true,
      description: "Recipient email address(es), comma-separated"
    ),
    Fields.string("cc", label: "CC"),
    Fields.string("bcc", label: "BCC"),
    Fields.string("subject", label: "Subject", required?: true),
    Fields.string("body",
      label: "Body",
      required?: true,
      description: "Email body (supports HTML)"
    ),
    Fields.string("reply_to_thread_id",
      label: "Reply-to Thread ID",
      description: "Thread ID to reply within"
    )
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "message_id" => %{"type" => "string"},
      "thread_id" => %{"type" => "string"},
      "status" => %{"type" => "string"}
    }
  }
end
