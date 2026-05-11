defmodule Fizz.Steps.Executors.GmailReplyEmail do
  @moduledoc """
  Replies to an existing Gmail thread.
  """

  use Fizz.Steps.Definition,
    id: "gmail_reply_email",
    name: "Gmail — Reply to Email",
    category: "Email",
    description: "Reply to an existing Gmail thread",
    icon: "/images/gmail.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Providers.GoogleOAuth
  alias Fizz.Slots.CredentialSlot

  @credential_slot CredentialSlot.oauth(GoogleOAuth.provider_id())

  @default_config %{
    "credential_ref" => CredentialSlot.declaration(@credential_slot)
  }

  @config_schema %{
    "type" => "object",
    "required" => ["thread_id", "body"],
    "properties" => %{
      "credential_ref" =>
        CredentialSlot.schema(@credential_slot,
          title: "Gmail Account",
          description: "Google account. Bound at run time per user."
        ),
      "thread_id" => %{
        "type" => "string",
        "title" => "Thread ID",
        "description" => "Gmail thread ID to reply to"
      },
      "body" => %{
        "type" => "string",
        "title" => "Reply Body"
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
    # TODO: Implement Gmail reply via Google API
    {:ok, %{}}
  end
end
