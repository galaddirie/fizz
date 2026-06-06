defmodule Fizz.Integrations.Library.Google.Docs do
  @moduledoc """
  Google Docs product integration catalog entry.
  """

  use Fizz.Integrations.Contracts.StaticIntegration,
    id: "google_docs",
    display_name: "Google Docs",
    provider_id: "google_oauth",
    actions: ["google_docs_create_doc", "google_docs_append_text"],
    step_modules: [
      Fizz.Integrations.Library.Google.Docs.Triggers.DocumentUpdated,
      Fizz.Integrations.Library.Google.Docs.Actions.CreateDocument,
      Fizz.Integrations.Library.Google.Docs.Actions.AppendText
    ]
end
