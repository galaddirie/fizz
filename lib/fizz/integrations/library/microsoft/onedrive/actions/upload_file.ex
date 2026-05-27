defmodule Fizz.Integrations.Library.Microsoft.OneDrive.Actions.UploadFile do
  @moduledoc """
  Uploads a file to Microsoft OneDrive.
  """

  use Fizz.Integrations.Steps.Definition,
    id: "onedrive_upload_file",
    name: "OneDrive — Upload File",
    category: "Documents",
    description: "Upload a file to Microsoft OneDrive personal or business storage",
    icon: "/images/microsoft.svg",
    kind: :action,
    provider: "microsoft_oauth",
    integration: "onedrive"

  use Fizz.Integrations.Steps.Placeholder

  alias Fizz.Integrations.Auth.Providers.MicrosoftOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(MicrosoftOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Microsoft Account",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("folder_path",
      label: "Folder Path",
      default: "/",
      description: "OneDrive folder path (e.g. /Documents/Reports/)"
    ),
    Fields.string("file_name", label: "File Name", required?: true),
    Fields.string("file_content",
      label: "File Content",
      required?: true,
      description: "Base64-encoded content or URL"
    ),
    Fields.select("conflict_behavior",
      label: "If File Exists",
      default: "rename",
      options: Fields.options(~w(rename replace fail))
    )
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "item_id" => %{"type" => "string"},
      "url" => %{"type" => "string"},
      "download_url" => %{"type" => "string"}
    }
  }
end
