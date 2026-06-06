defmodule Fizz.Integrations.Library.Google.Gmail.Actions.ReplyEmail do
  @moduledoc """
  Replies to an existing Gmail thread.
  """

  use Fizz.Integrations.Steps.Definition,
    id: "gmail_reply_email",
    name: "Gmail — Reply to Email",
    category: "Email",
    description: "Reply to an existing Gmail thread",
    icon: "/images/gmail.svg",
    kind: :action,
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
    Fields.string("thread_id",
      label: "Thread ID",
      required?: true,
      description: "Gmail thread ID to reply to"
    ),
    Fields.string("body", label: "Reply Body", required?: true)
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
