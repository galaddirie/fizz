defmodule Fizz.Integrations.Auth.Providers.GitHubApiKey do
  @moduledoc """
  GitHub API-key provider definition.

  Runtime API-key execution is not implemented for GitHub yet; OAuth remains
  the executable GitHub provider.
  """

  alias Fizz.Integrations.Auth.ProviderDefinition

  def provider_id, do: "github_api_key"
  def display_name, do: "GitHub"

  def definition do
    ProviderDefinition.api_key(
      id: provider_id(),
      label: display_name(),
      logo_path: "/images/github.svg"
    )
  end
end
