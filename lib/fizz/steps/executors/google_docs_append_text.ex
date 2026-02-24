defmodule Fizz.Steps.Executors.GoogleDocsAppendText do
  @moduledoc """
  Appends text to an existing Google Doc.
  """

  use Fizz.Steps.Definition,
    id: "google_docs_append_text",
    name: "Google Docs — Append Text",
    category: "Documents",
    description: "Append text or structured content to an existing Google Doc",
    icon: "/images/google_docs.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  @config_schema %{
    "type" => "object",
    "required" => ["document_id", "text"],
    "properties" => %{
      "credential_ref" => %{
        "type" => "object",
        "title" => "Google Account"
      },
      "document_id" => %{
        "type" => "string",
        "title" => "Document ID"
      },
      "text" => %{
        "type" => "string",
        "title" => "Text to Append"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "document_id" => %{"type" => "string"},
      "revision_id" => %{"type" => "string"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Google Docs batchUpdate insertText
    {:ok, %{}}
  end
end
