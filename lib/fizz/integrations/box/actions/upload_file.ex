defmodule Fizz.Integrations.Box.Actions.UploadFile do
  @moduledoc """
  Uploads a file to Box cloud storage.
  """

  use Fizz.Integrations.StepDefinition,
    id: "box_upload_file",
    name: "Box — Upload File",
    category: "Documents",
    description: "Upload a file to Box for secure cloud storage and collaboration",
    icon: "/images/box.svg",
    kind: :action,
    provider: "box_oauth",
    integration: "box"

  use Fizz.Integrations.PlaceholderStep

  alias Fizz.Integrations.Providers.BoxOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(BoxOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Box Account",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("parent_folder_id",
      label: "Parent Folder ID",
      description: "Box folder ID (0 for root)",
      default: "0"
    ),
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
      "file_id" => %{"type" => "string"},
      "file_name" => %{"type" => "string"},
      "url" => %{"type" => "string"},
      "shared_link" => %{"type" => "string"}
    }
  }
end
