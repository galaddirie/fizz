defmodule Fizz.Integrations.CredentialProviderCatalog do
  @moduledoc """
  Catalog of supported API key providers used by the credentials UI and backend.

  Entries are configurable via `:fizz, :integration_credential_providers`.
  """

  @default_providers [
    %{id: "openai", label: "OpenAI", logo_path: "/images/openai.svg", custom: false},
    %{id: "anthropic", label: "Anthropic", logo_path: "/images/anthropic.svg", custom: false},
    %{id: "github", label: "GitHub", logo_path: "/images/github.svg", custom: false},
    %{id: "custom", label: "Custom", logo_path: nil, custom: true}
  ]

  @spec providers() :: [map()]
  def providers do
    Application.get_env(:fizz, :integration_credential_providers, @default_providers)
    |> normalize_entries()
  end

  @spec provider_supported?(String.t()) :: boolean()
  def provider_supported?(provider_id) when is_binary(provider_id) do
    normalized_provider_id = provider_id |> String.trim() |> String.downcase()
    Enum.any?(providers(), &(&1.id == normalized_provider_id))
  end

  @spec provider(String.t()) :: {:ok, map()} | {:error, :unknown_provider}
  def provider(provider_id) when is_binary(provider_id) do
    normalized_provider_id = provider_id |> String.trim() |> String.downcase()

    case Enum.find(providers(), &(&1.id == normalized_provider_id)) do
      nil -> {:error, :unknown_provider}
      entry -> {:ok, entry}
    end
  end

  @spec provider_options() :: [{String.t(), String.t()}]
  def provider_options do
    providers()
    |> Enum.map(fn entry -> {entry.label, entry.id} end)
  end

  defp normalize_entries(entries) when is_list(entries) do
    entries
    |> Enum.map(&normalize_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_entries(_entries), do: @default_providers

  defp normalize_entry(entry) when is_map(entry) do
    id =
      (entry[:id] || entry["id"] || "")
      |> to_string()
      |> String.trim()
      |> String.downcase()

    label =
      (entry[:label] || entry["label"] || "")
      |> to_string()
      |> String.trim()

    logo_path = normalize_logo_path(entry[:logo_path] || entry["logo_path"])
    custom = entry[:custom] || entry["custom"] || false

    if id == "" or label == "" do
      nil
    else
      %{id: id, label: label, logo_path: logo_path, custom: custom in [true, "true", 1]}
    end
  end

  defp normalize_entry(_entry), do: nil

  defp normalize_logo_path(path) when is_binary(path) do
    trimmed_path = String.trim(path)
    if trimmed_path == "", do: nil, else: trimmed_path
  end

  defp normalize_logo_path(_path), do: nil
end
