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
  alias Fizz.Credentials.Requirement, as: CredentialRequirement

  @credential_requirement CredentialRequirement.oauth(NotionOAuth.provider_id())

  @default_config %{
    "credential_ref" => CredentialRequirement.declaration(@credential_requirement)
  }

  @config_schema %{
    "type" => "object",
    "required" => ["page_id"],
    "properties" => %{
      "credential_ref" =>
        CredentialRequirement.schema(@credential_requirement, title: "Notion Integration"),
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
