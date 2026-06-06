defmodule Fizz.TestSupport.CatalogValidation.AcmeDocs do
  @behaviour Fizz.Integrations.Contracts.Integration

  @impl true
  def id, do: "acme_docs"

  @impl true
  def display_name, do: "Acme Docs"

  @impl true
  def provider_id, do: "google_oauth"

  @impl true
  def actions, do: ["acme_docs_action"]

  @impl true
  def triggers, do: [Fizz.TestSupport.CatalogValidation.AcmeDocsTrigger]

  @impl true
  def step_modules, do: []

  @impl true
  def required_scopes(_operation), do: []
end
