defmodule Fizz.Integrations.Library.Google.Slides.Actions.AddSlide do
  @moduledoc """
  Adds a slide to a Google Slides presentation.
  """

  use Fizz.Integrations.Steps.Definition,
    id: "google_slides_add_slide",
    name: "Google Slides — Add Slide",
    category: "Documents",
    description: "Append a new slide with content to a Google Slides presentation",
    icon: "/images/google_slides.svg",
    kind: :action,
    provider: "google_oauth",
    integration: "google_slides"

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
    Fields.string("presentation_id", label: "Presentation ID", required?: true),
    Fields.select("layout",
      label: "Slide Layout",
      default: "TITLE_AND_BODY",
      options: Fields.options(~w(BLANK TITLE TITLE_AND_BODY SECTION_HEADER))
    ),
    Fields.string("title", label: "Slide Title"),
    Fields.string("body", label: "Slide Body Text")
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "slide_id" => %{"type" => "string"},
      "slide_index" => %{"type" => "integer"}
    }
  }
end
