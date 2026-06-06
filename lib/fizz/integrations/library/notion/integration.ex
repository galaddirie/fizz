defmodule Fizz.Integrations.Library.Notion do
  @moduledoc """
  Notion product integration catalog entry.
  """

  use Fizz.Integrations.Contracts.StaticIntegration,
    id: "notion",
    display_name: "Notion",
    provider_id: "notion_oauth",
    actions: ["notion_create_page", "notion_update_page"],
    step_modules: [
      Fizz.Integrations.Library.Notion.Triggers.PageUpdated,
      Fizz.Integrations.Library.Notion.Actions.CreatePage,
      Fizz.Integrations.Library.Notion.Actions.UpdatePage
    ]
end
