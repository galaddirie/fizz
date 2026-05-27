defmodule Fizz.Integrations.Auth.Providers.NotionOAuth do
  @moduledoc """
  Notion OAuth provider backed by WorkOS Pipes.
  """

  @behaviour Fizz.Integrations.Contracts.Provider

  alias Fizz.Integrations.Auth.ProviderDefinition
  alias Fizz.Integrations.Auth.Providers.PipesOAuth

  @provider_slug "notion"

  @impl true
  def provider_id, do: "notion_oauth"

  @impl true
  def display_name, do: "Notion"

  @impl true
  def definition do
    ProviderDefinition.oauth(__MODULE__,
      id: provider_id(),
      label: display_name(),
      logo_path: "/images/notion.svg"
    )
  end

  @impl true
  def check_connection(scope, organization_id),
    do: PipesOAuth.check_connection(scope, organization_id, @provider_slug)

  @impl true
  def fetch_token(scope, organization_id),
    do: PipesOAuth.fetch_token(scope, organization_id, @provider_slug)

  @impl true
  def network_domains, do: ["api.notion.com", "www.notion.so"]
end
