defmodule Fizz.Integrations.ProviderCatalog do
  @moduledoc """
  Authoritative catalog of integration provider definitions.

  Provider IDs are auth-type specific to keep OAuth and API credential providers
  cleanly separated (for example `github_oauth` vs `github_api_key`).
  """

  @builtin_provider_modules [
    Fizz.Integrations.Providers.GitHubOAuth,
    Fizz.Integrations.Providers.GitHubApiKey,
    Fizz.Integrations.Providers.OpenAIApiKey,
    Fizz.Integrations.Providers.AnthropicApiKey,
    Fizz.Integrations.Providers.SlackOAuth,
    Fizz.Integrations.Providers.GoogleOAuth,
    Fizz.Integrations.Providers.MicrosoftOAuth,
    Fizz.Integrations.Providers.NotionOAuth,
    Fizz.Integrations.Providers.BoxOAuth,
    Fizz.Integrations.Providers.CustomApiKey
  ]

  @spec providers() :: [map()]
  def providers do
    case Application.get_env(:fizz, :integration_providers) do
      entries when is_list(entries) ->
        normalize_entries(entries)

      _ ->
        builtin_providers()
    end
  end

  @spec provider(String.t()) :: {:ok, map()} | {:error, :unknown_provider}
  def provider(provider_id) when is_binary(provider_id) do
    normalized_provider_id = normalize_provider_id(provider_id)

    case Enum.find(providers(), &(&1.id == normalized_provider_id)) do
      nil -> {:error, :unknown_provider}
      entry -> {:ok, entry}
    end
  end

  @spec provider_supported?(String.t()) :: boolean()
  def provider_supported?(provider_id) when is_binary(provider_id) do
    match?({:ok, _entry}, provider(provider_id))
  end

  @spec provider_supports_auth_method?(String.t(), :oauth | :api_key) :: boolean()
  def provider_supports_auth_method?(provider_id, auth_method)
      when auth_method in [:oauth, :api_key] do
    match?({:ok, _}, provider_for_type(provider_id, auth_method))
  end

  @spec provider_for_type(String.t(), :oauth | :api_key) :: {:ok, map()} | {:error, term()}
  def provider_for_type(provider_id, auth_type)
      when is_binary(provider_id) and auth_type in [:oauth, :api_key] do
    with {:ok, resolved_provider_id} <- resolve_provider_id_for_type(provider_id, auth_type) do
      provider(resolved_provider_id)
    end
  end

  @spec resolve_provider_id_for_type(String.t(), :oauth | :api_key) ::
          {:ok, String.t()} | {:error, :unknown_provider | :unsupported_auth_method}
  def resolve_provider_id_for_type(provider_id, auth_type)
      when is_binary(provider_id) and auth_type in [:oauth, :api_key] do
    normalized_provider_id = normalize_provider_id(provider_id)

    cond do
      provider_exists_for_type?(normalized_provider_id, auth_type) ->
        {:ok, normalized_provider_id}

      match?({:ok, _entry}, provider(normalized_provider_id)) ->
        {:error, :unsupported_auth_method}

      true ->
        {:error, :unknown_provider}
    end
  end

  @spec oauth_provider_module(String.t()) :: {:ok, module()} | {:error, term()}
  def oauth_provider_module(provider_id) when is_binary(provider_id) do
    with {:ok, entry} <- provider_for_type(provider_id, :oauth),
         module when is_atom(module) and not is_nil(module) <- entry.oauth_module do
      {:ok, module}
    else
      nil -> {:error, :provider_not_implemented}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :provider_not_implemented}
    end
  end

  @spec api_key_provider_module(String.t()) :: {:ok, module()} | {:error, term()}
  def api_key_provider_module(provider_id) when is_binary(provider_id) do
    with {:ok, entry} <- provider_for_type(provider_id, :api_key),
         module when is_atom(module) and not is_nil(module) <- entry.api_key_module do
      {:ok, module}
    else
      nil -> {:error, :provider_not_implemented}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :provider_not_implemented}
    end
  end

  @spec api_key_providers() :: [map()]
  def api_key_providers do
    providers()
    |> Enum.filter(&(&1.type == :api_key))
  end

  @spec api_key_provider_options() :: [{String.t(), String.t()}]
  def api_key_provider_options do
    api_key_providers()
    |> Enum.map(fn entry -> {entry.label, entry.id} end)
  end

  defp normalize_entries(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(&normalize_entry/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_entries(_entries), do: builtin_providers()

  defp normalize_entry(entry) when is_map(entry) do
    id = normalize_provider_id(entry[:id] || entry["id"] || "")

    label =
      (entry[:label] || entry["label"] || "")
      |> to_string()
      |> String.trim()

    logo_path = normalize_logo_path(entry[:logo_path] || entry["logo_path"])
    custom = entry[:custom] || entry["custom"] || false
    type = normalize_auth_type(entry[:type] || entry["type"])
    oauth_module = normalize_oauth_module(entry[:oauth_module] || entry["oauth_module"])

    api_key_module =
      normalize_api_key_module(entry[:api_key_module] || entry["api_key_module"])

    cond do
      id == "" or label == "" ->
        []

      type not in [:oauth, :api_key] ->
        []

      not provider_id_has_type_suffix?(id, type) ->
        []

      true ->
        [
          %{
            id: id,
            label: label,
            logo_path: logo_path,
            custom: custom in [true, "true", 1],
            type: type,
            oauth_module: if(type == :oauth, do: oauth_module, else: nil),
            api_key_module: if(type == :api_key, do: api_key_module, else: nil)
          }
        ]
    end
  end

  defp normalize_entry(module) when is_atom(module) do
    case provider_definition(module) do
      {:ok, definition} -> normalize_entry(definition)
      :error -> []
    end
  end

  defp normalize_entry(_entry), do: []

  defp builtin_providers do
    Enum.map(@builtin_provider_modules, &provider_definition!/1)
  end

  defp provider_definition!(module) do
    case provider_definition(module) do
      {:ok, definition} -> definition
      :error -> raise ArgumentError, "provider module #{inspect(module)} must define definition/0"
    end
  end

  defp provider_definition(module) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :definition, 0),
         definition when is_map(definition) <- module.definition() do
      {:ok, definition}
    else
      _ -> :error
    end
  end

  defp normalize_provider_id(provider_id) do
    provider_id
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_logo_path(path) when is_binary(path) do
    trimmed_path = String.trim(path)
    if trimmed_path == "", do: nil, else: trimmed_path
  end

  defp normalize_logo_path(_path), do: nil

  defp normalize_auth_type(type) when type in [:oauth, :api_key], do: type
  defp normalize_auth_type("oauth"), do: :oauth
  defp normalize_auth_type("api_key"), do: :api_key
  defp normalize_auth_type(_type), do: nil

  defp provider_id_has_type_suffix?(provider_id, :oauth),
    do: String.ends_with?(provider_id, "_oauth")

  defp provider_id_has_type_suffix?(provider_id, :api_key),
    do: String.ends_with?(provider_id, "_api_key")

  defp provider_exists_for_type?(provider_id, auth_type) do
    case provider(provider_id) do
      {:ok, entry} -> entry.type == auth_type
      {:error, :unknown_provider} -> false
    end
  end

  defp normalize_oauth_module(module) when is_atom(module), do: module
  defp normalize_oauth_module(_module), do: nil

  defp normalize_api_key_module(module) when is_atom(module), do: module
  defp normalize_api_key_module(_module), do: nil
end
