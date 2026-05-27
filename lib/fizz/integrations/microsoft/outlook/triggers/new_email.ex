defmodule Fizz.Integrations.Microsoft.Outlook.Triggers.NewEmail do
  @moduledoc """
  Trigger that fires when a new email arrives in Microsoft Outlook.
  """

  use Fizz.Integrations.StepDefinition,
    id: "outlook_trigger",
    name: "Outlook — New Email",
    category: "Triggers",
    description: "Fires when a new email arrives in a Microsoft Outlook inbox",
    icon: "/images/microsoft_outlook.svg",
    kind: :trigger,
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
    Fields.string("folder", label: "Folder", default: "Inbox"),
    Fields.string("from_filter", label: "From Filter")
  ]

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
end
