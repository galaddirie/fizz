defmodule Fizz.Integrations.ProviderCatalog do
  @moduledoc """
  Authoritative catalog of integration provider definitions.

  Provider IDs are auth-type specific to keep OAuth and API credential providers
  cleanly separated (for example `github_oauth` vs `github_api_key`).
  """

  @replacement_config_key :replace_integration_providers_for_test

  @spec providers() :: [map()]
  def providers do
    configured_providers()
    |> provider_entries()
    |> validate_providers!()
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

  @doc false
  @spec validate_providers!([map()]) :: [map()]
  def validate_providers!(providers) when is_list(providers) do
    providers
    |> validate_unique_ids!()
    |> Enum.each(&validate_provider!/1)

    providers
  end

  def validate_providers!(_providers) do
    raise ArgumentError, "integration providers must be a list"
  end

  defp provider_entries(configured_providers) do
    if replace_provider_catalog?() do
      configured_providers
    else
      builtin_providers() ++ configured_providers
    end
  end

  defp configured_providers do
    case Application.get_env(:fizz, :integration_providers, []) do
      entries when is_list(entries) ->
        normalize_entries(entries)

      nil ->
        []

      other ->
        raise ArgumentError, ":integration_providers must be a list, got: #{inspect(other)}"
    end
  end

  defp replace_provider_catalog? do
    Application.get_env(:fizz, @replacement_config_key, false) == true
  end

  defp normalize_entries(entries) when is_list(entries) do
    Enum.map(entries, &normalize_entry/1)
  end

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

    %{
      id: id,
      label: label,
      logo_path: logo_path,
      custom: custom in [true, "true", 1],
      type: type,
      oauth_module: if(type == :oauth, do: oauth_module, else: nil),
      api_key_module: if(type == :api_key, do: api_key_module, else: nil)
    }
  end

  defp normalize_entry(module) when is_atom(module) do
    case provider_definition(module) do
      {:ok, definition} -> normalize_entry(definition)
      :error -> raise ArgumentError, "provider module #{inspect(module)} must define definition/0"
    end
  end

  defp normalize_entry(entry) do
    raise ArgumentError, "invalid provider catalog entry: #{inspect(entry)}"
  end

  defp builtin_providers do
    Fizz.Integrations.Manifest.provider_modules()
    |> Enum.map(&provider_definition!/1)
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

  defp validate_unique_ids!(providers) do
    duplicate_ids =
      providers
      |> Enum.map(& &1.id)
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(fn {id, _count} -> id end)
      |> Enum.sort()

    case duplicate_ids do
      [] -> providers
      ids -> raise ArgumentError, "duplicate integration provider IDs: #{inspect(ids)}"
    end
  end

  defp validate_provider!(provider) do
    validate_required_provider_fields!(provider)
    validate_provider_auth_type!(provider)
    validate_provider_icon!(provider)
    validate_provider_modules!(provider)
  end

  defp validate_required_provider_fields!(%{id: id, label: label})
       when is_binary(id) and id != "" and is_binary(label) and label != "",
       do: :ok

  defp validate_required_provider_fields!(provider) do
    raise ArgumentError, "provider entry requires non-empty id and label: #{inspect(provider)}"
  end

  defp validate_provider_auth_type!(%{id: id, type: type}) when type in [:oauth, :api_key] do
    case provider_id_has_type_suffix?(id, type) do
      true -> :ok
      false -> raise ArgumentError, "provider #{id} ID does not match auth type #{type}"
    end
  end

  defp validate_provider_auth_type!(provider) do
    raise ArgumentError, "provider entry has unsupported auth type: #{inspect(provider)}"
  end

  defp validate_provider_icon!(%{custom: true}), do: :ok

  defp validate_provider_icon!(%{id: id, logo_path: logo_path})
       when is_binary(logo_path) and logo_path != "" do
    case String.starts_with?(logo_path, "/") do
      true -> :ok
      false -> raise ArgumentError, "provider #{id} logo_path must be an absolute asset path"
    end
  end

  defp validate_provider_icon!(%{id: id}) do
    raise ArgumentError, "provider #{id} is missing logo_path"
  end

  defp validate_provider_modules!(%{type: :oauth, id: id, oauth_module: module})
       when is_atom(module) and not is_nil(module) do
    validate_provider_module_loaded!(id, module)
  end

  defp validate_provider_modules!(%{type: :oauth, id: id}) do
    raise ArgumentError, "OAuth provider #{id} is missing oauth_module"
  end

  defp validate_provider_modules!(%{type: :api_key, id: id, api_key_module: module})
       when is_atom(module) and not is_nil(module) do
    validate_provider_module_loaded!(id, module)
  end

  defp validate_provider_modules!(%{type: :api_key}), do: :ok

  defp validate_provider_module_loaded!(id, module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> :ok
      _ -> raise ArgumentError, "provider #{id} module #{inspect(module)} is not loaded"
    end
  end
end
