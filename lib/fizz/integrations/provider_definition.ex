defmodule Fizz.Integrations.ProviderDefinition do
  @moduledoc """
  Builder for provider catalog entries.

  Provider metadata lives with the provider module; the catalog only assembles
  these definitions into a lookup table.
  """

  alias Fizz.Fields
  alias Fizz.Fields.Definition, as: FieldDefinition

  @type auth_type :: :oauth | :api_key

  @type t :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:logo_path) => String.t() | nil,
          required(:custom) => boolean(),
          required(:type) => auth_type(),
          required(:oauth_module) => module() | nil,
          required(:api_key_module) => module() | nil,
          required(:credential_fields) => [FieldDefinition.t()],
          required(:credential_test) => map()
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
    id = required_string!(opts, :id)
    label = required_string!(opts, :label)
    module = Keyword.get(modules, :oauth_module) || Keyword.get(modules, :api_key_module)

    %{
      id: id,
      label: label,
      logo_path: optional_string(opts, :logo_path),
      custom: Keyword.get(opts, :custom, false),
      type: type,
      oauth_module: Keyword.get(modules, :oauth_module),
      api_key_module: Keyword.get(modules, :api_key_module),
      credential_fields:
        Keyword.get(opts, :credential_fields, default_credential_fields(type, id, label)),
      credential_test:
        Keyword.get(opts, :credential_test, default_credential_test(type, id, module))
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

  defp default_credential_fields(:api_key, id, label) do
    [
      Fields.password("secret",
        label: "#{label} API key",
        required?: true,
        default: "",
        autocomplete: "new-password",
        placeholder: api_key_placeholder(id),
        order: 10
      )
    ]
  end

  defp default_credential_fields(:oauth, _id, _label), do: []

  defp default_credential_test(:api_key, _id, module) when is_atom(module) do
    %{"type" => "api_key", "module" => Atom.to_string(module), "operation" => "check_connection"}
  end

  defp default_credential_test(:api_key, id, _module) do
    %{"type" => "api_key", "provider" => id, "operation" => "vault_lookup"}
  end

  defp default_credential_test(:oauth, id, _module) do
    %{"type" => "oauth", "provider" => id, "operation" => "connection_status"}
  end

  defp api_key_placeholder("openai_api_key"), do: "sk-..."
  defp api_key_placeholder("anthropic_api_key"), do: "sk-ant-..."
  defp api_key_placeholder("github_api_key"), do: "ghp_..."
  defp api_key_placeholder(_provider_id), do: "Enter API key"
end
