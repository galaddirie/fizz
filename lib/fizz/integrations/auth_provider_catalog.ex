defmodule Fizz.Integrations.AuthProviderCatalog do
  @moduledoc """
  Integrations-backed implementation of the Accounts auth provider lookup boundary.
  """

  @behaviour Fizz.Accounts.AuthProviderCatalog

  alias Fizz.Integrations.ProviderCatalog

  @impl true
  def resolve_provider_id_for_type(provider_id, auth_type) do
    ProviderCatalog.resolve_provider_id_for_type(provider_id, auth_type)
  end

  @impl true
  def provider_for_type(provider_id, auth_type) do
    ProviderCatalog.provider_for_type(provider_id, auth_type)
  end

  @impl true
  def provider(provider_id) do
    ProviderCatalog.provider(provider_id)
  end

  @impl true
  def credential_secret_value(provider_id, attrs) do
    Fizz.Integrations.CredentialSchema.secret_value(provider_id, attrs)
  end
end
