defmodule Fizz.Integrations.Providers.SlackOAuth do
  @moduledoc """
  Slack OAuth provider backed by WorkOS Pipes.
  """

  @behaviour Fizz.Integrations.Provider

  alias Fizz.Integrations.ProviderDefinition
  alias Fizz.Integrations.Providers.PipesOAuth

  @provider_slug "slack"

  @impl true
  def provider_id, do: "slack_oauth"

  @impl true
  def display_name, do: "Slack"

  @impl true
  def definition do
    ProviderDefinition.oauth(__MODULE__,
      id: provider_id(),
      label: display_name(),
      logo_path: "/images/slack.svg"
    )
  end

  @impl true
  def check_connection(scope, organization_id),
    do: PipesOAuth.check_connection(scope, organization_id, @provider_slug)

  @impl true
  def fetch_token(scope, organization_id),
    do: PipesOAuth.fetch_token(scope, organization_id, @provider_slug)

  @impl true
  def network_domains, do: ["slack.com", "api.slack.com"]
end
