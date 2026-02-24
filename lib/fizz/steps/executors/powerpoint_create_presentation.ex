defmodule Fizz.Steps.Executors.PowerPointCreatePresentation do
  @moduledoc """
  Creates a Microsoft PowerPoint presentation via Microsoft Graph.
  """

  use Fizz.Steps.Definition,
    id: "powerpoint_create_presentation",
    name: "PowerPoint — Create Presentation",
    category: "Documents",
    description: "Create a new PowerPoint presentation in OneDrive or SharePoint",
    icon: "/images/microsoft_powerpoint.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  @config_schema %{
    "type" => "object",
    "required" => ["file_name"],
    "properties" => %{
      "credential_ref" => %{
        "type" => "object",
        "title" => "Microsoft Account"
      },
      "file_name" => %{
        "type" => "string",
        "title" => "File Name",
        "description" => "Name for the .pptx file"
      },
      "folder_path" => %{
        "type" => "string",
        "title" => "Folder Path",
        "default" => "/"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "item_id" => %{"type" => "string"},
      "url" => %{"type" => "string"},
      "web_url" => %{"type" => "string"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Microsoft Graph workbook / presentation creation
    {:ok, %{}}
  end
end
