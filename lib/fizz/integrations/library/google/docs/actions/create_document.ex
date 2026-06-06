defmodule Fizz.Integrations.Library.Google.Docs.Actions.CreateDocument do
  @moduledoc """
  Creates a new Google Doc with optional content.
  """

  use Fizz.Integrations.Steps.Definition,
    id: "google_docs_create_doc",
    name: "Google Docs — Create Document",
    category: "Documents",
    description: "Create a new Google Doc with optional text content",
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
    Fields.string("title", label: "Document Title", required?: true),
    Fields.string("body_text",
      label: "Initial Content",
      description: "Plain text to insert as the document body"
    ),
    Fields.string("folder_id",
      label: "Destination Folder ID",
      description: "Google Drive folder ID"
    )
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "document_id" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "url" => %{"type" => "string"}
    }
  }
end
