defmodule Fizz.TestSupport.CatalogValidation.UnknownProviderIntegration do
  @behaviour Fizz.Integrations.Integration

  @impl true
  def id, do: "unknown_provider_docs"

  @impl true
  def display_name, do: "Unknown Provider Docs"

  @impl true
  def provider_id, do: "missing_oauth"

  @impl true
  def actions, do: []

  @impl true
  def triggers, do: []

  @impl true
  def required_scopes(_operation), do: []
end
