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

  @behaviour Fizz.Steps.Executor

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

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Gmail reply via Google API
    {:ok, %{}}
  end
end
