defmodule Fizz.Integrations.Providers.OpenAIApiKey do
  @moduledoc """
  OpenAI integration provider backed by user-owned Vault API credentials.
  """

  @behaviour Fizz.Integrations.Provider

  alias Fizz.Accounts.ExternalAuth

  @impl true
  def provider_id, do: "openai_api_key"

  @impl true
  def display_name, do: "OpenAI"

  @impl true
  def check_connection(_scope, nil), do: {:error, :organization_scope_required}

  def check_connection(scope, organization_id) when is_binary(organization_id) do
    case ExternalAuth.resolve_credential_for_use(scope, organization_id, provider_id()) do
      {:ok, credential_result} ->
        {:ok,
         %{
           active: true,
           scopes: [],
           missing_scopes: [],
           provider_metadata: credential_metadata(credential_result),
           error: nil
         }}

      {:error, :credential_not_found} ->
        {:ok,
         %{
           active: false,
           scopes: [],
           missing_scopes: [],
           provider_metadata: %{},
           error: :credential_not_found
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_token(_scope, nil), do: {:error, :organization_scope_required}

  def fetch_token(scope, organization_id) when is_binary(organization_id) do
    with {:ok, credential_result} <-
           ExternalAuth.resolve_credential_for_use(scope, organization_id, provider_id()) do
      {:ok,
       %{
         access_token: credential_result.api_key,
         expires_at: nil,
         scopes: [],
         missing_scopes: [],
         api_credential_id: credential_result.api_credential_id,
         credential_id: credential_result.credential_id
       }}
    end
  end

  @impl true
  def network_domains do
    ["api.openai.com"]
  end

  defp credential_metadata(credential_result) do
    %{
      "api_credential_id" => credential_result.api_credential_id,
      "provider_label" => credential_result.provider_label,
      "provider_custom_name" => credential_result.provider_custom_name
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
