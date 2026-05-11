defmodule Fizz.Integrations.Providers.CustomApiKey do
  @moduledoc """
  User-defined API-key provider definition.
  """

  alias Fizz.Integrations.ProviderDefinition

  def provider_id, do: "custom_api_key"
  def display_name, do: "Custom"

  def definition do
    ProviderDefinition.api_key(
      id: provider_id(),
      label: display_name(),
      custom: true
    )
  end
end
