defmodule Fizz.Integrations.Google.Docs do
  @moduledoc """
  Google Docs product integration catalog entry.
  """

  use Fizz.Integrations.StaticIntegration,
    id: "google_docs",
    display_name: "Google Docs",
    provider_id: "google_oauth",
    actions: ["google_docs_create_doc", "google_docs_append_text"],
    step_modules: [
      Fizz.Integrations.Google.Docs.Triggers.DocumentUpdated,
      Fizz.Integrations.Google.Docs.Actions.CreateDocument,
      Fizz.Integrations.Google.Docs.Actions.AppendText
    ]
end
