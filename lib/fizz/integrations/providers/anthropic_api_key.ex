defmodule Fizz.Integrations.Providers.AnthropicApiKey do
  @moduledoc """
  Anthropic API-key provider definition.

  Token resolution is not implemented yet; the catalog still exposes the
  provider so credential slots and account configuration can target it.
  """

  alias Fizz.Integrations.ProviderDefinition

  def provider_id, do: "anthropic_api_key"
  def display_name, do: "Anthropic"

  def definition do
    ProviderDefinition.api_key(
      id: provider_id(),
      label: display_name(),
      logo_path: "/images/anthropic.svg"
    )
  end
end
