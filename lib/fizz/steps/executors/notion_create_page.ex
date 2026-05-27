defmodule Fizz.Steps.Executors.NotionCreatePage do
  @moduledoc """
  Creates a new page in a Notion database.
  """

  use Fizz.Steps.Definition,
    id: "notion_create_page",
    name: "Notion — Create Page",
    category: "Documents",
    description: "Create a new page or database entry in Notion",
    icon: "/images/notion.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Providers.NotionOAuth
  alias Fizz.Credentials.Requirement, as: CredentialRequirement

  @credential_requirement CredentialRequirement.oauth(NotionOAuth.provider_id())

  @default_config %{
    "credential_ref" => CredentialRequirement.declaration(@credential_requirement)
  }

  @config_schema %{
    "type" => "object",
    "required" => ["database_id", "title"],
    "properties" => %{
      "credential_ref" =>
        CredentialRequirement.schema(@credential_requirement, title: "Notion Integration"),
      "database_id" => %{
        "type" => "string",
        "title" => "Database ID"
      },
      "title" => %{
        "type" => "string",
        "title" => "Page Title"
      },
      "properties" => %{
        "type" => "object",
        "title" => "Additional Properties",
        "description" => "Map of Notion property name → value"
      },
      "content" => %{
        "type" => "string",
        "title" => "Page Body Content",
        "description" => "Markdown-style text for the page body blocks"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "page_id" => %{"type" => "string"},
      "url" => %{"type" => "string"},
      "title" => %{"type" => "string"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Notion pages.create
    {:ok, %{}}
  end
end
