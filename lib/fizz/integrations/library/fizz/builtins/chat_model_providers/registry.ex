defmodule Fizz.Integrations.Library.Fizz.Builtins.ChatModelProviders.Registry do
  @moduledoc false

  alias Fizz.Integrations.Catalog.Manifest
  alias Fizz.Integrations.Library.Fizz.Builtins.ChatModelProviders.Provider

  @spec fetch(String.t()) :: {:ok, module()} | {:error, term()}
  def fetch(prefix) when is_binary(prefix) do
    case Map.fetch(provider_index(), prefix) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unsupported_model_provider, prefix}}
    end
  end

  @spec provider_modules() :: [module()]
  def provider_modules do
    Application.get_env(:fizz, __MODULE__, [])
    |> Keyword.get(:provider_modules, Manifest.chat_model_provider_modules())
  end

  @spec provider_index() :: %{String.t() => module()}
  def provider_index do
    provider_modules()
    |> Enum.reduce(%{}, fn module, acc ->
      validate_provider_module!(module)
      prefix = module.provider_prefix()

      case Map.has_key?(acc, prefix) do
        true ->
          raise ArgumentError, "duplicate chat model provider prefix #{inspect(prefix)}"

        false ->
          Map.put(acc, prefix, module)
      end
    end)
  end

  defp validate_provider_module!(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        unless function_exported?(module, :provider_prefix, 0) and
                 function_exported?(module, :generate, 2) do
          raise ArgumentError,
                "#{inspect(module)} must implement #{inspect(Provider)} callbacks"
        end

      _ ->
        raise ArgumentError, "chat model provider #{inspect(module)} could not be loaded"
    end
  end

  defp validate_provider_module!(module) do
    raise ArgumentError, "chat model provider must be a module atom, got: #{inspect(module)}"
  end
end
