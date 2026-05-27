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

  @behaviour Fizz.Steps.Executor

  alias Fizz.Integrations.Providers.NotionOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(NotionOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Notion Integration",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("database_id", label: "Database ID", required?: true),
    Fields.string("title", label: "Page Title", required?: true),
    Fields.json("properties",
      label: "Additional Properties",
      description: "Map of Notion property name -> value"
    ),
    Fields.string("content",
      label: "Page Body Content",
      description: "Markdown-style text for the page body blocks"
    )
  ]

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
