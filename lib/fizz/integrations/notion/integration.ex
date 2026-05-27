defmodule Fizz.Integrations.Notion do
  @moduledoc """
  Notion product integration catalog entry.
  """

  use Fizz.Integrations.StaticIntegration,
    id: "notion",
    display_name: "Notion",
    provider_id: "notion_oauth",
    actions: ["notion_create_page", "notion_update_page"],
    step_modules: [
      Fizz.Integrations.Notion.Triggers.PageUpdated,
      Fizz.Integrations.Notion.Actions.CreatePage,
      Fizz.Integrations.Notion.Actions.UpdatePage
    ]
end
