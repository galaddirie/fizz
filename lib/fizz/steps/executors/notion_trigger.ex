defmodule Fizz.Steps.Executors.NotionTrigger do
  @moduledoc """
  Trigger that fires when a Notion page is created or updated.
  """

  use Fizz.Steps.Definition,
    id: "notion_trigger",
    name: "Notion — Page Updated",
    category: "Triggers",
    description: "Fires when a page in a Notion database is created or updated",
    icon: "/images/notion.svg",
    kind: :trigger

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Providers.NotionOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(NotionOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      requirement_key: "auth"
                    )

  @default_config %{
    "credential_ref" => Fields.default_value(@credential_field)
  }

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "credential_ref" =>
        Fields.to_schema_property(@credential_field, label: "Notion Integration"),
      "database_id" => %{
        "type" => "string",
        "title" => "Database ID",
        "description" => "Notion database to watch"
      },
      "event_type" => %{
        "type" => "string",
        "title" => "Event Type",
        "enum" => ["created", "updated", "both"],
        "default" => "both"
      }
    }
  }

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

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Notion polling / webhook trigger
    {:ok, %{}}
  end
end
