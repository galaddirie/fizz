defmodule Fizz.Steps.Executors.SharePointUploadFile do
  @moduledoc """
  Uploads a file to a Microsoft SharePoint document library.
  """

  use Fizz.Steps.Definition,
    id: "sharepoint_upload_file",
    name: "SharePoint — Upload File",
    category: "Documents",
    description: "Upload a file to a SharePoint document library or folder",
    icon: "/images/microsoft_sharepoint.svg",
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
    "required" => ["site_id", "file_name", "file_content"],
    "properties" => %{
      "credential_ref" =>
        Fields.to_schema_property(@credential_field, label: "Microsoft Account"),
      "site_id" => %{
        "type" => "string",
        "title" => "SharePoint Site ID"
      },
      "drive_id" => %{
        "type" => "string",
        "title" => "Drive ID",
        "description" => "Leave blank for default Documents library"
      },
      "folder_path" => %{
        "type" => "string",
        "title" => "Folder Path",
        "default" => "/"
      },
      "file_name" => %{
        "type" => "string",
        "title" => "File Name"
      },
      "file_content" => %{
        "type" => "string",
        "title" => "File Content",
        "description" => "Base64-encoded content or URL"
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
    # TODO: Implement Microsoft Graph driveItem upload
    {:ok, %{}}
  end
end
