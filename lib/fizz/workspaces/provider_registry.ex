defmodule Fizz.Workspaces.ProviderRegistry do
  @moduledoc """
  Resolves the configured workspace provider module.
  """

  @providers %{
    "sprites" => Fizz.Workspaces.Providers.Sprites
  }

  @spec provider() :: {:ok, module()} | {:error, :workspace_provider_not_configured | term()}
  def provider do
    case configured_provider_id() do
      nil ->
        {:error, :workspace_provider_not_configured}

      provider_id ->
        case Map.fetch(@providers, provider_id) do
          {:ok, provider_module} -> {:ok, provider_module}
          :error -> {:error, {:unknown_workspace_provider, provider_id}}
        end
    end
  end

  defp configured_provider_id do
    case Application.get_env(:fizz, :workspaces, []) do
      settings when is_list(settings) ->
        settings
        |> Keyword.get(:provider)
        |> normalize_provider_id()

      _ ->
        nil
    end
  end

  defp normalize_provider_id(provider_id) when is_binary(provider_id) do
    provider_id
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_provider_id(provider_id) when is_atom(provider_id) do
    provider_id
    |> Atom.to_string()
    |> normalize_provider_id()
  end

  defp normalize_provider_id(_provider_id), do: nil
end
