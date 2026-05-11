defmodule Fizz.Integrations.ProviderDefinition do
  @moduledoc """
  Builder for provider catalog entries.

  Provider metadata lives with the provider module; the catalog only assembles
  these definitions into a lookup table.
  """

  @type auth_type :: :oauth | :api_key

  @type t :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:logo_path) => String.t() | nil,
          required(:custom) => boolean(),
          required(:type) => auth_type(),
          required(:oauth_module) => module() | nil,
          required(:api_key_module) => module() | nil
        }

  @spec oauth(module(), keyword()) :: t()
  def oauth(module, opts) when is_atom(module) and is_list(opts) do
    definition(:oauth, opts, oauth_module: module)
  end

  @spec api_key(module(), keyword()) :: t()
  def api_key(module, opts) when is_atom(module) and is_list(opts) do
    definition(:api_key, opts, api_key_module: module)
  end

  @spec api_key(keyword()) :: t()
  def api_key(opts) when is_list(opts) do
    definition(:api_key, opts, api_key_module: nil)
  end

  defp definition(type, opts, modules) when type in [:oauth, :api_key] do
    %{
      id: required_string!(opts, :id),
      label: required_string!(opts, :label),
      logo_path: optional_string(opts, :logo_path),
      custom: Keyword.get(opts, :custom, false),
      type: type,
      oauth_module: Keyword.get(modules, :oauth_module),
      api_key_module: Keyword.get(modules, :api_key_module)
    }
  end

  defp required_string!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) ->
        value

      _ ->
        raise ArgumentError, "provider definition requires #{key}"
    end
  end

  defp optional_string(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
