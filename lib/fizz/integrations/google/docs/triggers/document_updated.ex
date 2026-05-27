defmodule Fizz.Integrations.Google.Docs.Triggers.DocumentUpdated do
  @moduledoc """
  Trigger that fires when a Google Doc is updated.
  """

  use Fizz.Integrations.StepDefinition,
    id: "google_docs_trigger",
    name: "Google Docs — Doc Updated",
    category: "Triggers",
    description: "Fires when a Google Doc is created or modified",
    icon: "/images/google_docs.svg",
    kind: :trigger,
    provider: "google_oauth",
    integration: "google_docs"

  use Fizz.Integrations.PlaceholderStep

  alias Fizz.Integrations.Providers.GoogleOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(GoogleOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Google Account",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("document_id",
      label: "Document ID",
      description: "Leave blank to watch any doc in Drive"
    )
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "document_id" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "modified_at" => %{"type" => "string"},
      "url" => %{"type" => "string"}
    }
  }
end
