defmodule Fizz.Integrations.Definition do
  @moduledoc """
  Validators and normalization helpers for unified integration definitions.
  """

  alias Fizz.Fields

  @spec validate_provider!(struct()) :: struct()
  def validate_provider!(%Fizz.Integrations.Definition.Provider{} = provider) do
    validate_required_string!(provider.id, "provider id")
    validate_required_string!(provider.label, "provider label")
    Fields.validate!(provider.credential_fields)
    provider
  end

  def validate_provider!(provider) do
    raise ArgumentError, "invalid provider definition: #{inspect(provider)}"
  end

  @spec validate_providers!([struct()]) :: [struct()]
  def validate_providers!(providers) when is_list(providers) do
    providers
    |> validate_unique_by!(& &1.id, "provider IDs")
    |> Enum.map(&validate_provider!/1)
  end

  def validate_providers!(providers) do
    raise ArgumentError, "provider definitions must be a list, got: #{inspect(providers)}"
  end

  @spec supported_field_components() :: [String.t()]
  def supported_field_components, do: Fields.supported_components()

  defp validate_required_string!(value, _label) when is_binary(value) and value != "", do: :ok

  defp validate_required_string!(value, label) do
    raise ArgumentError, "#{label} must be a non-empty string, got: #{inspect(value)}"
  end

  defp validate_unique_by!(entries, mapper, label) do
    duplicate_values =
      entries
      |> Enum.map(mapper)
      |> Enum.frequencies()
      |> Enum.filter(fn {_value, count} -> count > 1 end)
      |> Enum.map(fn {value, _count} -> value end)
      |> Enum.sort()

    case duplicate_values do
      [] -> entries
      values -> raise ArgumentError, "duplicate #{label}: #{inspect(values)}"
    end
  end
end
