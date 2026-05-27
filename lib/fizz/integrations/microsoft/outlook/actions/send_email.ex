defmodule Fizz.Integrations.Microsoft.Outlook.Actions.SendEmail do
  @moduledoc """
  Sends an email via Microsoft Outlook / Exchange.
  """

  use Fizz.Integrations.StepDefinition,
    id: "outlook_send_email",
    name: "Outlook — Send Email",
    category: "Email",
    description: "Send an email via Microsoft Outlook or Exchange",
    icon: "/images/microsoft_outlook.svg",
    kind: :action,
    provider: "microsoft_oauth",
    integration: "outlook"

  use Fizz.Integrations.PlaceholderStep

  alias Fizz.Integrations.Providers.MicrosoftOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(MicrosoftOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Microsoft Account",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("to", label: "To", required?: true),
    Fields.string("cc", label: "CC"),
    Fields.string("bcc", label: "BCC"),
    Fields.string("subject", label: "Subject", required?: true),
    Fields.string("body",
      label: "Body",
      required?: true,
      description: "Supports HTML"
    )
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "message_id" => %{"type" => "string"},
      "status" => %{"type" => "string"}
    }
  }
end
