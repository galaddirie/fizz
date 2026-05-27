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

  @behaviour Fizz.Steps.Executor

  alias Fizz.Integrations.Providers.MicrosoftOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(MicrosoftOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Microsoft Account",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("file_name",
      label: "File Name",
      required?: true,
      description: "Name for the .pptx file"
    ),
    Fields.string("folder_path", label: "Folder Path", default: "/")
  ]

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
