defmodule Fizz.Integrations.ProviderCatalog do
  @moduledoc """
  Authoritative catalog of integration provider definitions.

  Provider IDs are auth-type specific to keep OAuth and API credential providers
  cleanly separated (for example `github_oauth` vs `github_api_key`).
  """

  @default_providers [
    %{
      id: "github_oauth",
      label: "GitHub",
      logo_path: "/images/github.svg",
      custom: false,
      type: :oauth,
      oauth_module: Fizz.Integrations.Providers.GitHubOAuth
    },
    %{
      id: "github_api_key",
      label: "GitHub",
      logo_path: "/images/github.svg",
      custom: false,
      type: :api_key,
      oauth_module: nil
    },
    %{
      id: "openai_api_key",
      label: "OpenAI",
      logo_path: "/images/openai.svg",
      custom: false,
      type: :api_key,
      oauth_module: nil
    },
    %{
      id: "anthropic_api_key",
      label: "Anthropic",
      logo_path: "/images/anthropic.svg",
      custom: false,
      type: :api_key,
      oauth_module: nil
    },
    %{
      id: "custom_api_key",
      label: "Custom",
      logo_path: nil,
      custom: true,
      type: :api_key,
      oauth_module: nil
    }
  ]

  @legacy_provider_aliases %{
    {"github", :oauth} => "github_oauth",
    {"github", :api_key} => "github_api_key",
    {"openai", :api_key} => "openai_api_key",
    {"anthropic", :api_key} => "anthropic_api_key",
    {"custom", :api_key} => "custom_api_key"
  }

  @spec providers() :: [map()]
  def providers do
    case Application.get_env(:fizz, :integration_providers) do
      entries when is_list(entries) ->
        normalize_entries(entries)

      _ ->
        providers_from_legacy_credential_catalog()
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
    case provider(provider_id) do
      {:ok, _entry} ->
        true

      {:error, :unknown_provider} ->
        provider_known_for_any_type?(normalize_provider_id(provider_id))
    end
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
      provider_id_has_type_suffix?(normalized_provider_id, auth_type) ->
        if provider_exists_for_type?(normalized_provider_id, auth_type) do
          {:ok, normalized_provider_id}
        else
          {:error, :unknown_provider}
        end

      legacy_provider_alias = @legacy_provider_aliases[{normalized_provider_id, auth_type}] ->
        if provider_exists_for_type?(legacy_provider_alias, auth_type) do
          {:ok, legacy_provider_alias}
        else
          {:error, :unknown_provider}
        end

      provider_exists_for_type?(normalized_provider_id, auth_type) ->
        {:ok, normalized_provider_id}

      provider_known_for_any_type?(normalized_provider_id) ->
        {:error, :unsupported_auth_method}

      true ->
        {:error, :unknown_provider}
    end
  end

  @spec oauth_provider_module(String.t()) :: {:ok, module()} | {:error, term()}
  def oauth_provider_module(provider_id) when is_binary(provider_id) do
    with {:ok, entry} <- provider_for_type(provider_id, :oauth),
         module when is_atom(module) <- entry.oauth_module do
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

  defp normalize_entries(_entries), do: @default_providers

  defp providers_from_legacy_credential_catalog do
    case Application.get_env(:fizz, :integration_credential_providers) do
      entries when is_list(entries) ->
        entries
        |> normalize_legacy_api_key_entries()
        |> merge_with_defaults()

      _ ->
        @default_providers
    end
  end

  defp normalize_legacy_api_key_entries(entries) do
    entries
    |> Enum.flat_map(&normalize_entry(Map.put(&1, :type, :api_key)))
    |> Enum.reject(&is_nil/1)
  end

  defp merge_with_defaults(legacy_entries) do
    default_map = Map.new(@default_providers, &{&1.id, &1})
    legacy_map = Map.new(legacy_entries, &{&1.id, &1})
    provider_ids = (Map.keys(default_map) ++ Map.keys(legacy_map)) |> Enum.uniq()

    provider_ids
    |> Enum.map(fn provider_id ->
      merge_entry_maps(default_map[provider_id], legacy_map[provider_id])
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp merge_entry_maps(nil, legacy_entry), do: legacy_entry
  defp merge_entry_maps(default_entry, nil), do: default_entry

  defp merge_entry_maps(default_entry, legacy_entry) do
    %{
      id: default_entry.id,
      label: legacy_entry.label || default_entry.label,
      logo_path: legacy_entry.logo_path || default_entry.logo_path,
      custom: legacy_entry.custom || default_entry.custom,
      type: legacy_entry.type || default_entry.type,
      oauth_module: default_entry.oauth_module || legacy_entry.oauth_module
    }
  end

  defp normalize_entry(entry) when is_map(entry) do
    id = normalize_provider_id(entry[:id] || entry["id"] || "")

    label =
      (entry[:label] || entry["label"] || "")
      |> to_string()
      |> String.trim()

    logo_path = normalize_logo_path(entry[:logo_path] || entry["logo_path"])
    custom = entry[:custom] || entry["custom"] || false
    auth_type = normalize_type(entry[:type] || entry["type"])
    auth_methods = normalize_auth_methods(entry[:auth_methods] || entry["auth_methods"])
    types = normalize_types(auth_type, auth_methods)
    oauth_module = normalize_oauth_module(entry[:oauth_module] || entry["oauth_module"])

    cond do
      id == "" or label == "" ->
        []

      types == [] ->
        []

      true ->
        Enum.map(types, fn type ->
          %{
            id: typed_provider_id(id, type),
            label: label,
            logo_path: logo_path,
            custom: custom in [true, "true", 1],
            type: type,
            oauth_module: if(type == :oauth, do: oauth_module, else: nil)
          }
        end)
    end
  end

  defp normalize_entry(_entry), do: []

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

  defp normalize_auth_methods(methods) when is_list(methods) do
    methods
    |> Enum.map(&normalize_auth_method/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_auth_methods(_methods), do: []

  defp normalize_auth_method(method) when method in [:oauth, :api_key], do: method
  defp normalize_auth_method("oauth"), do: :oauth
  defp normalize_auth_method("api_key"), do: :api_key
  defp normalize_auth_method(_method), do: nil

  defp normalize_type(type), do: normalize_auth_method(type)

  defp normalize_types(type, _auth_methods) when type in [:oauth, :api_key], do: [type]
  defp normalize_types(nil, auth_methods), do: auth_methods

  defp provider_id_has_type_suffix?(provider_id, :oauth),
    do: String.ends_with?(provider_id, "_oauth")

  defp provider_id_has_type_suffix?(provider_id, :api_key),
    do: String.ends_with?(provider_id, "_api_key")

  defp typed_provider_id(provider_id, auth_type) do
    cond do
      provider_id_has_type_suffix?(provider_id, auth_type) ->
        provider_id

      auth_type == :oauth ->
        "#{provider_id}_oauth"

      auth_type == :api_key ->
        "#{provider_id}_api_key"
    end
  end

  defp provider_exists_for_type?(provider_id, auth_type) do
    case provider(provider_id) do
      {:ok, entry} -> entry.type == auth_type
      {:error, :unknown_provider} -> false
    end
  end

  defp provider_known_for_any_type?(provider_id) do
    match?({:ok, _}, provider(provider_id)) ||
      Enum.any?([:oauth, :api_key], fn auth_type ->
        legacy_provider_alias = @legacy_provider_aliases[{provider_id, auth_type}]

        is_binary(legacy_provider_alias) and
          provider_exists_for_type?(legacy_provider_alias, auth_type)
      end) ||
      Enum.any?([:oauth, :api_key], fn auth_type ->
        candidate_provider_id = typed_provider_id(provider_id, auth_type)

        candidate_provider_id != provider_id and
          provider_exists_for_type?(candidate_provider_id, auth_type)
      end)
  end

  defp normalize_oauth_module(module) when is_atom(module), do: module
  defp normalize_oauth_module(_module), do: nil
end
