defmodule Fizz.Steps.Executors.GoogleSlidesCreatePresentation do
  @moduledoc """
  Creates a new Google Slides presentation.
  """

  use Fizz.Steps.Definition,
    id: "google_slides_create_presentation",
    name: "Google Slides — Create Presentation",
    category: "Documents",
    description: "Create a new Google Slides presentation from a template or blank",
    icon: "/images/google_slides.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Providers.GoogleOAuth
  alias Fizz.Credentials.Requirement, as: CredentialRequirement

  @credential_requirement CredentialRequirement.oauth(GoogleOAuth.provider_id())

  @default_config %{
    "credential_ref" => CredentialRequirement.declaration(@credential_requirement)
  }

  @config_schema %{
    "type" => "object",
    "required" => ["title"],
    "properties" => %{
      "credential_ref" =>
        CredentialRequirement.schema(@credential_requirement,
          title: "Google Account"
        ),
      "title" => %{
        "type" => "string",
        "title" => "Presentation Title"
      },
      "template_id" => %{
        "type" => "string",
        "title" => "Template Presentation ID",
        "description" => "Copy from this Google Slides file instead of creating blank"
      },
      "folder_id" => %{
        "type" => "string",
        "title" => "Destination Folder ID"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "presentation_id" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "url" => %{"type" => "string"},
      "slide_count" => %{"type" => "integer"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Google Slides API create / copy
    {:ok, %{}}
  end
end
