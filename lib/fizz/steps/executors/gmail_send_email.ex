defmodule Fizz.Steps.Executors.GmailSendEmail do
  @moduledoc """
  Sends an email via Gmail / Google project.
  """

  use Fizz.Steps.Definition,
    id: "gmail_send_email",
    name: "Gmail — Send Email",
    category: "Email",
    description: "Send an email via Gmail or Google project",
    icon: "/images/gmail.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Providers.GoogleOAuth
  alias Fizz.Credentials.Requirement, as: CredentialRequirement

  @credential_requirement CredentialRequirement.oauth(GoogleOAuth.provider_id())

  @default_config %{
    "credential_ref" => CredentialRequirement.declaration(@credential_requirement)
  }

  @config_schema %{
    "type" => "object",
    "required" => ["to", "subject", "body"],
    "properties" => %{
      "credential_ref" =>
        CredentialRequirement.schema(@credential_requirement,
          title: "Gmail Account",
          description: "Google account. Bound at run time per user."
        ),
      "to" => %{
        "type" => "string",
        "title" => "To",
        "description" => "Recipient email address(es), comma-separated"
      },
      "cc" => %{"type" => "string", "title" => "CC"},
      "bcc" => %{"type" => "string", "title" => "BCC"},
      "subject" => %{"type" => "string", "title" => "Subject"},
      "body" => %{
        "type" => "string",
        "title" => "Body",
        "description" => "Email body (supports HTML)"
      },
      "reply_to_thread_id" => %{
        "type" => "string",
        "title" => "Reply-to Thread ID",
        "description" => "Thread ID to reply within"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "message_id" => %{"type" => "string"},
      "thread_id" => %{"type" => "string"},
      "status" => %{"type" => "string"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Gmail send via Google API
    {:ok, %{}}
  end
end
