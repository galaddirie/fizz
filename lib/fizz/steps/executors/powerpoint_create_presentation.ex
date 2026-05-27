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

  alias Fizz.Integrations.Providers.MicrosoftOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(MicrosoftOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      requirement_key: "auth"
                    )

  @default_config %{
    "credential_ref" => Fields.default_value(@credential_field)
  }

  @config_schema %{
    "type" => "object",
    "required" => ["file_name"],
    "properties" => %{
      "credential_ref" =>
        Fields.to_schema_property(@credential_field,
          label: "Microsoft Account"
        ),
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
