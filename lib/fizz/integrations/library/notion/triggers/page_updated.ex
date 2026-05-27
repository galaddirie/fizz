defmodule Fizz.Integrations.Library.Notion.Triggers.PageUpdated do
  @moduledoc """
  Trigger that fires when a Notion page is created or updated.
  """

  use Fizz.Integrations.Steps.Definition,
    id: "notion_trigger",
    name: "Notion — Page Updated",
    category: "Triggers",
    description: "Fires when a page in a Notion database is created or updated",
    icon: "/images/notion.svg",
    kind: :trigger,
    provider: "notion_oauth",
    integration: "notion"

  use Fizz.Integrations.Steps.Placeholder

  alias Fizz.Integrations.Auth.Providers.NotionOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(NotionOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Notion Integration",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("database_id",
      label: "Database ID",
      description: "Notion database to watch"
    ),
    Fields.select("event_type",
      label: "Event Type",
      default: "both",
      options: Fields.options(~w(created updated both))
    )
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "page_id" => %{"type" => "string"},
      "url" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "properties" => %{"type" => "object", "description" => "Notion page properties map"},
      "created_time" => %{"type" => "string"},
      "last_edited_time" => %{"type" => "string"}
    }
  }
end
