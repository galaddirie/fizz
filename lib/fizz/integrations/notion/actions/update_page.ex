defmodule Fizz.Integrations.Notion.Actions.UpdatePage do
  @moduledoc """
  Updates properties of an existing Notion page.
  """

  use Fizz.Integrations.StepDefinition,
    id: "notion_update_page",
    name: "Notion — Update Page",
    category: "Documents",
    description: "Update properties or content of an existing Notion page",
    icon: "/images/notion.svg",
    kind: :action,
    provider: "notion_oauth",
    integration: "notion"

  use Fizz.Integrations.PlaceholderStep

  alias Fizz.Integrations.Providers.NotionOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(NotionOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Notion Integration",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("page_id", label: "Page ID", required?: true),
    Fields.json("properties", label: "Properties to Update")
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "page_id" => %{"type" => "string"},
      "url" => %{"type" => "string"},
      "last_edited_time" => %{"type" => "string"}
    }
  }
end
