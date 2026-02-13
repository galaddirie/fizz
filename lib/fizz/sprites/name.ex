defmodule Fizz.Sprites.Name do
  @moduledoc """
  Deterministic naming helpers for multi-tenant sprite workspaces.
  """

  alias Fizz.Sprites.Config

  @tenant_hash_len 10
  @workspace_hash_len 6
  @workspace_slug_len 20

  @spec normalize_workspace_key(String.t() | nil) :: String.t()
  def normalize_workspace_key(workspace_key) do
    workspace_key
    |> to_string_safe()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "default"
      value -> String.slice(value, 0, 48)
    end
  end

  @spec workspace_id(String.t(), String.t()) :: String.t()
  def workspace_id(tenant_id, workspace_key) do
    payload = "#{tenant_id}:#{workspace_key}"
    "wsp_" <> short_hash(payload, 24)
  end

  @spec tenant_prefix(String.t()) :: String.t()
  def tenant_prefix(tenant_id) do
    prefix = normalize_prefix(Config.name_prefix())
    tenant_hash = short_hash(tenant_id, @tenant_hash_len)

    "#{prefix}-t#{tenant_hash}-"
  end

  @spec sprite_name(String.t(), String.t()) :: String.t()
  def sprite_name(tenant_id, workspace_key) do
    prefix = normalize_prefix(Config.name_prefix())
    tenant_hash = short_hash(tenant_id, @tenant_hash_len)

    workspace_slug = String.slice(normalize_workspace_key(workspace_key), 0, @workspace_slug_len)
    workspace_hash = short_hash(workspace_key, @workspace_hash_len)

    "#{prefix}-t#{tenant_hash}-w#{workspace_slug}-#{workspace_hash}"
  end

  defp normalize_prefix(value) do
    value
    |> to_string_safe()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "fizz"
      trimmed -> String.slice(trimmed, 0, 20)
    end
  end

  defp short_hash(value, length) do
    value
    |> to_string_safe()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, length)
  end

  defp to_string_safe(nil), do: ""
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: to_string(value)
end
