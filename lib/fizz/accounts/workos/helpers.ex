defmodule Fizz.Accounts.WorkOS.Helpers do
  @moduledoc false

  @doc """
  Reads the first non-nil value from a map for a list of candidate keys.
  """
  def read_value(data, keys) do
    Enum.find_value(keys, fn key ->
      case data do
        %{} -> Map.get(data, key)
        _ -> nil
      end
    end)
  end

  @doc """
  Coerces a value to an integer, returning nil on failure.
  """
  def normalize_integer(value) when is_integer(value), do: value

  def normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  def normalize_integer(_value), do: nil

  @doc """
  Extracts all role slugs from a WorkOS membership payload.
  """
  def membership_role_slugs(membership) do
    role_slugs =
      membership
      |> read_value([:roles, "roles"])
      |> List.wrap()
      |> Enum.map(fn role -> read_value(role, [:slug, "slug"]) end)
      |> Enum.filter(&is_binary/1)

    primary_role_slug =
      case read_value(membership, [:role, "role", :role_slug, "role_slug"]) do
        %{} = role -> read_value(role, [:slug, "slug"])
        slug when is_binary(slug) -> slug
        _ -> nil
      end

    [primary_role_slug | role_slugs]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end
end
