defmodule Fizz.Integrations.CredentialProviderCatalog do
  @moduledoc """
  Backwards-compatible API-key provider catalog used by credentials UI flows.

  Delegates to `Fizz.Integrations.ProviderCatalog`.
  """

  alias Fizz.Integrations.ProviderCatalog

  @spec providers() :: [map()]
  def providers do
    ProviderCatalog.api_key_providers()
  end

  @spec provider_supported?(String.t()) :: boolean()
  def provider_supported?(provider_id) when is_binary(provider_id) do
    ProviderCatalog.provider_supports_auth_method?(provider_id, :api_key)
  end

  @spec provider(String.t()) :: {:ok, map()} | {:error, :unknown_provider}
  def provider(provider_id) when is_binary(provider_id) do
    case ProviderCatalog.provider(provider_id) do
      {:ok, %{type: :api_key} = entry} ->
        {:ok, entry}

      {:ok, _entry} ->
        case ProviderCatalog.provider_for_type(provider_id, :api_key) do
          {:ok, entry} -> {:ok, entry}
          {:error, _reason} -> {:error, :unknown_provider}
        end

      {:error, :unknown_provider} ->
        case ProviderCatalog.provider_for_type(provider_id, :api_key) do
          {:ok, entry} ->
            {:ok, entry}

          {:error, _reason} ->
            {:error, :unknown_provider}
        end
    end
  end

  @spec provider_options() :: [{String.t(), String.t()}]
  def provider_options do
    ProviderCatalog.api_key_provider_options()
  end
end
