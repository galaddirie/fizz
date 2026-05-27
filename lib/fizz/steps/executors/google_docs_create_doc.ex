defmodule Fizz.Steps.Executors.GoogleDocsCreateDoc do
  @moduledoc """
  Creates a new Google Doc with optional content.
  """

  use Fizz.Steps.Definition,
    id: "google_docs_create_doc",
    name: "Google Docs — Create Document",
    category: "Documents",
    description: "Create a new Google Doc with optional text content",
    icon: "/images/google_docs.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Providers.GoogleOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(GoogleOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      requirement_key: "auth"
                    )

  @default_config %{
    "credential_ref" => Fields.default_value(@credential_field)
  }

  @config_schema %{
    "type" => "object",
    "required" => ["title"],
    "properties" => %{
      "credential_ref" => Fields.to_schema_property(@credential_field, label: "Google Account"),
      "title" => %{
        "type" => "string",
        "title" => "Document Title"
      },
      "body_text" => %{
        "type" => "string",
        "title" => "Initial Content",
        "description" => "Plain text to insert as the document body"
      },
      "folder_id" => %{
        "type" => "string",
        "title" => "Destination Folder ID",
        "description" => "Google Drive folder ID"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "document_id" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "url" => %{"type" => "string"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Google Docs API create
    {:ok, %{}}
  end
end
