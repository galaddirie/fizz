defmodule Fizz.Steps.Executors.OutlookSendEmail do
  @moduledoc """
  Sends an email via Microsoft Outlook / Exchange.
  """

  use Fizz.Steps.Definition,
    id: "outlook_send_email",
    name: "Outlook — Send Email",
    category: "Email",
    description: "Send an email via Microsoft Outlook or Exchange",
    icon: "/images/microsoft_outlook.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Providers.MicrosoftOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(MicrosoftOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      requirement_key: "auth"
                    )

  @default_config %{
    "credential_ref" => Fields.default_value(@credential_field)
  }

  @config_schema %{
    "type" => "object",
    "required" => ["to", "subject", "body"],
    "properties" => %{
      "credential_ref" =>
        Fields.to_schema_property(@credential_field, label: "Microsoft Account"),
      "to" => %{"type" => "string", "title" => "To"},
      "cc" => %{"type" => "string", "title" => "CC"},
      "bcc" => %{"type" => "string", "title" => "BCC"},
      "subject" => %{"type" => "string", "title" => "Subject"},
      "body" => %{
        "type" => "string",
        "title" => "Body",
        "description" => "Supports HTML"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "message_id" => %{"type" => "string"},
      "status" => %{"type" => "string"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Microsoft Graph sendMail
    {:ok, %{}}
  end
end
