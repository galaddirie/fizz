defmodule Fizz.Steps.Executors.BoxUploadFile do
  @moduledoc """
  Uploads a file to Box cloud storage.
  """

  use Fizz.Steps.Definition,
    id: "box_upload_file",
    name: "Box — Upload File",
    category: "Documents",
    description: "Upload a file to Box for secure cloud storage and collaboration",
    icon: "/images/box.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  @config_schema %{
    "type" => "object",
    "required" => ["file_name", "file_content"],
    "properties" => %{
      "credential_ref" => %{
        "type" => "object",
        "title" => "Box Account"
      },
      "parent_folder_id" => %{
        "type" => "string",
        "title" => "Parent Folder ID",
        "description" => "Box folder ID (0 for root)",
        "default" => "0"
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
      "file_id" => %{"type" => "string"},
      "file_name" => %{"type" => "string"},
      "url" => %{"type" => "string"},
      "shared_link" => %{"type" => "string"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Box API file upload
    {:ok, %{}}
  end
end
