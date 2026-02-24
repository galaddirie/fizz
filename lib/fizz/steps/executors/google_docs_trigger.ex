defmodule Fizz.Steps.Executors.GoogleDocsTrigger do
  @moduledoc """
  Trigger that fires when a Google Doc is updated.
  """

  use Fizz.Steps.Definition,
    id: "google_docs_trigger",
    name: "Google Docs — Doc Updated",
    category: "Triggers",
    description: "Fires when a Google Doc is created or modified",
    icon: "/images/google_docs.svg",
    kind: :trigger

  @behaviour Fizz.Steps.Executors.Behaviour

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "credential_ref" => %{
        "type" => "object",
        "title" => "Google Account"
      },
      "document_id" => %{
        "type" => "string",
        "title" => "Document ID",
        "description" => "Leave blank to watch any doc in Drive"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "document_id" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "modified_at" => %{"type" => "string"},
      "url" => %{"type" => "string"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Google Drive / Docs change webhook
    {:ok, %{}}
  end
end
