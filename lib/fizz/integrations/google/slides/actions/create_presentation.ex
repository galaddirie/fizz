defmodule Fizz.Integrations.Google.Slides.Actions.CreatePresentation do
  @moduledoc """
  Creates a new Google Slides presentation.
  """

  use Fizz.Integrations.StepDefinition,
    id: "google_slides_create_presentation",
    name: "Google Slides — Create Presentation",
    category: "Documents",
    description: "Create a new Google Slides presentation from a template or blank",
    icon: "/images/google_slides.svg",
    kind: :action,
    provider: "google_oauth",
    integration: "google_slides"

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
    Fields.string("title", label: "Presentation Title", required?: true),
    Fields.string("template_id",
      label: "Template Presentation ID",
      description: "Copy from this Google Slides file instead of creating blank"
    ),
    Fields.string("folder_id", label: "Destination Folder ID")
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "presentation_id" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "url" => %{"type" => "string"},
      "slide_count" => %{"type" => "integer"}
    }
  }
end
