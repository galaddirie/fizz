defmodule Fizz.Integrations.Library.Google.Docs.Actions.AppendText do
  @moduledoc """
  Appends text to an existing Google Doc.
  """

  use Fizz.Integrations.Steps.Definition,
    id: "google_docs_append_text",
    name: "Google Docs — Append Text",
    category: "Documents",
    description: "Append text or structured content to an existing Google Doc",
    icon: "/images/google_docs.svg",
    kind: :action,
    provider: "google_oauth",
    integration: "google_docs"

  use Fizz.Integrations.Steps.Placeholder

  alias Fizz.Integrations.Auth.Providers.GoogleOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(GoogleOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Google Account",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("document_id", label: "Document ID", required?: true),
    Fields.string("text", label: "Text to Append", required?: true)
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "document_id" => %{"type" => "string"},
      "revision_id" => %{"type" => "string"}
    }
  }
end
