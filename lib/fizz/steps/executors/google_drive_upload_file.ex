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

  @behaviour Fizz.Steps.Executors.Behaviour

  @config_schema %{
    "type" => "object",
    "required" => ["file_name", "file_content"],
    "properties" => %{
      "credential_ref" => %{
        "type" => "object",
        "title" => "Google Account"
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
      "mime_type" => %{
        "type" => "string",
        "title" => "MIME Type",
        "default" => "application/pdf"
      },
      "folder_id" => %{
        "type" => "string",
        "title" => "Destination Folder ID"
      }
    }
  }

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
