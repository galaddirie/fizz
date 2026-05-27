defmodule Fizz.Steps.Executors.GoogleDriveUploadFile do
  @moduledoc """
  Uploads a file to Google Drive.
  """

  use Fizz.Steps.Definition,
    id: "google_drive_upload_file",
    name: "Google Drive — Upload File",
    category: "Documents",
    description: "Upload a file (PDF, image, etc.) to Google Drive",
    icon: "/images/google_drive.svg",
    kind: :action

  @behaviour Fizz.Steps.Executor

  alias Fizz.Integrations.Providers.GoogleOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(GoogleOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Google Account",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("file_name", label: "File Name", required?: true),
    Fields.string("file_content",
      label: "File Content",
      required?: true,
      description: "Base64-encoded content or URL"
    ),
    Fields.string("mime_type", label: "MIME Type", default: "application/pdf"),
    Fields.string("folder_id", label: "Destination Folder ID")
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "file_id" => %{"type" => "string"},
      "file_name" => %{"type" => "string"},
      "url" => %{"type" => "string"},
      "web_view_link" => %{"type" => "string"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Google Drive files.create multipart upload
    {:ok, %{}}
  end
end
