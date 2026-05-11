defmodule Fizz.Steps.Executors.OneDriveUploadFile do
  @moduledoc """
  Uploads a file to Microsoft OneDrive.
  """

  use Fizz.Steps.Definition,
    id: "onedrive_upload_file",
    name: "OneDrive — Upload File",
    category: "Documents",
    description: "Upload a file to Microsoft OneDrive personal or business storage",
    icon: "/images/microsoft.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Providers.MicrosoftOAuth
  alias Fizz.Slots.CredentialSlot

  @credential_slot CredentialSlot.oauth(MicrosoftOAuth.provider_id())

  @default_config %{
    "credential_ref" => CredentialSlot.declaration(@credential_slot)
  }

  @config_schema %{
    "type" => "object",
    "required" => ["file_name", "file_content"],
    "properties" => %{
      "credential_ref" => CredentialSlot.schema(@credential_slot, title: "Microsoft Account"),
      "folder_path" => %{
        "type" => "string",
        "title" => "Folder Path",
        "description" => "OneDrive folder path (e.g. /Documents/Reports/)",
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
      },
      "conflict_behavior" => %{
        "type" => "string",
        "title" => "If File Exists",
        "enum" => ["rename", "replace", "fail"],
        "default" => "rename"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "item_id" => %{"type" => "string"},
      "url" => %{"type" => "string"},
      "download_url" => %{"type" => "string"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Microsoft Graph OneDrive upload
    {:ok, %{}}
  end
end
