defmodule Fizz.Integrations.Providers.BoxOAuth do
  @moduledoc """
  Box OAuth provider backed by WorkOS Pipes.
  """

  @behaviour Fizz.Integrations.Provider

  alias Fizz.Integrations.ProviderDefinition
  alias Fizz.Integrations.Providers.PipesOAuth

  @provider_slug "box"

  @impl true
  def provider_id, do: "box_oauth"

  @impl true
  def display_name, do: "Box"

  @impl true
  def definition do
    ProviderDefinition.oauth(__MODULE__,
      id: provider_id(),
      label: display_name(),
      logo_path: "/images/box.svg"
    )
  end

  @impl true
  def check_connection(scope, organization_id),
    do: PipesOAuth.check_connection(scope, organization_id, @provider_slug)

  @impl true
  def fetch_token(scope, organization_id),
    do: PipesOAuth.fetch_token(scope, organization_id, @provider_slug)

  @impl true
  def network_domains, do: ["account.box.com", "api.box.com", "upload.box.com"]
end
