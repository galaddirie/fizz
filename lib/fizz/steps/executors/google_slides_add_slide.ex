defmodule Fizz.Steps.Executors.GoogleSlidesAddSlide do
  @moduledoc """
  Adds a slide to a Google Slides presentation.
  """

  use Fizz.Steps.Definition,
    id: "google_slides_add_slide",
    name: "Google Slides — Add Slide",
    category: "Documents",
    description: "Append a new slide with content to a Google Slides presentation",
    icon: "/images/google_slides.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Providers.GoogleOAuth
  alias Fizz.Slots.CredentialSlot

  @credential_slot CredentialSlot.oauth(GoogleOAuth.provider_id())

  @default_config %{
    "credential_ref" => CredentialSlot.declaration(@credential_slot)
  }

  @config_schema %{
    "type" => "object",
    "required" => ["presentation_id"],
    "properties" => %{
      "credential_ref" => CredentialSlot.schema(@credential_slot, title: "Google Account"),
      "presentation_id" => %{
        "type" => "string",
        "title" => "Presentation ID"
      },
      "layout" => %{
        "type" => "string",
        "title" => "Slide Layout",
        "enum" => ["BLANK", "TITLE", "TITLE_AND_BODY", "SECTION_HEADER"],
        "default" => "TITLE_AND_BODY"
      },
      "title" => %{
        "type" => "string",
        "title" => "Slide Title"
      },
      "body" => %{
        "type" => "string",
        "title" => "Slide Body Text"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "slide_id" => %{"type" => "string"},
      "slide_index" => %{"type" => "integer"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Google Slides batchUpdate createSlide
    {:ok, %{}}
  end
end
