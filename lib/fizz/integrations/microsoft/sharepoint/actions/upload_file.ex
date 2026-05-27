defmodule Fizz.Integrations.Microsoft.SharePoint.Actions.UploadFile do
  @moduledoc """
  Uploads a file to a Microsoft SharePoint document library.
  """

  use Fizz.Integrations.StepDefinition,
    id: "sharepoint_upload_file",
    name: "SharePoint — Upload File",
    category: "Documents",
    description: "Upload a file to a SharePoint document library or folder",
    icon: "/images/microsoft_sharepoint.svg",
    kind: :action,
    provider: "microsoft_oauth",
    integration: "sharepoint"

  use Fizz.Integrations.PlaceholderStep

  alias Fizz.Integrations.Providers.MicrosoftOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(MicrosoftOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Microsoft Account",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("site_id", label: "SharePoint Site ID", required?: true),
    Fields.string("drive_id",
      label: "Drive ID",
      description: "Leave blank for default Documents library"
    ),
    Fields.string("folder_path", label: "Folder Path", default: "/"),
    Fields.string("file_name", label: "File Name", required?: true),
    Fields.string("file_content",
      label: "File Content",
      required?: true,
      description: "Base64-encoded content or URL"
    )
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "item_id" => %{"type" => "string"},
      "url" => %{"type" => "string"},
      "web_url" => %{"type" => "string"}
    }
  }
end
