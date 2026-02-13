defmodule Fizz.Sprites.Config do
  @moduledoc """
  Runtime configuration accessors for the Sprites broker.
  """

  @default_base_url "https://api.sprites.dev"
  @default_name_prefix "fizz"
  @default_cmd_timeout_ms 30_000

  @spec configured?() :: boolean()
  def configured?, do: is_binary(api_key())

  @spec api_key() :: String.t() | nil
  def api_key do
    sprites_config()
    |> Keyword.get(:api_key)
    |> normalize_binary()
  end

  @spec base_url() :: String.t()
  def base_url do
    sprites_config()
    |> Keyword.get(:base_url, @default_base_url)
    |> to_string()
    |> String.trim_trailing("/")
  end

  @spec name_prefix() :: String.t()
  def name_prefix do
    sprites_config()
    |> Keyword.get(:name_prefix, @default_name_prefix)
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> @default_name_prefix
      value -> String.slice(value, 0, 20)
    end
  end

  @spec cmd_timeout_ms() :: pos_integer()
  def cmd_timeout_ms do
    sprites_config()
    |> Keyword.get(:cmd_timeout_ms, @default_cmd_timeout_ms)
    |> normalize_timeout(@default_cmd_timeout_ms)
  end

  defp sprites_config, do: Application.get_env(:fizz, :sprites, [])

  defp normalize_binary(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      nil
    else
      trimmed
    end
  end

  defp normalize_binary(_value), do: nil

  defp normalize_timeout(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_timeout(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_timeout(_value, default), do: default
end
