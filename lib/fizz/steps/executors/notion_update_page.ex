defmodule Fizz.Steps.Executors.NotionUpdatePage do
  @moduledoc """
  Updates properties of an existing Notion page.
  """

  use Fizz.Steps.Definition,
    id: "notion_update_page",
    name: "Notion — Update Page",
    category: "Documents",
    description: "Update properties or content of an existing Notion page",
    icon: "/images/notion.svg",
    kind: :action

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
    "required" => ["page_id"],
    "properties" => %{
      "credential_ref" =>
        Fields.to_schema_property(@credential_field, label: "Notion Integration"),
      "page_id" => %{
        "type" => "string",
        "title" => "Page ID"
      },
      "properties" => %{
        "type" => "object",
        "title" => "Properties to Update"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "page_id" => %{"type" => "string"},
      "url" => %{"type" => "string"},
      "last_edited_time" => %{"type" => "string"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Notion pages.update
    {:ok, %{}}
  end
end
