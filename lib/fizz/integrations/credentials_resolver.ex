defmodule Fizz.Integrations.CredentialsResolver do
  @moduledoc """
  Resolves credential options for workflow step config fields.

  Implements `Fizz.Steps.Resolver` so step executors can reference this module
  directly in their config schema.
  """

  @behaviour Fizz.Steps.Resolver

  alias Fizz.Accounts.Scope
  alias Fizz.Slots.Resolvers.Credential, as: CredentialSlotResolver

  @max_options 50

  @impl true
  def resolve(%{q: query, params: params, context: context}) do
    with {:ok, scope} <- fetch_scope(context),
         {:ok, options} <-
           CredentialSlotResolver.options_for_spec(
             spec_from_params(params),
             scope,
             q: query,
             limit: @max_options
           ) do
      {:ok, options}
    end
  end

  defp fetch_scope(context) when is_map(context) do
    case fetch_value(context, :current_scope) do
      %Scope{} = scope -> {:ok, scope}
      _ -> {:error, :scope_not_available}
    end
  end

  defp fetch_scope(_context), do: {:error, :scope_not_available}

  defp spec_from_params(params) do
    params = normalize_params(params)

    %{}
    |> maybe_put("provider", list_param(params, :provider_filter))
    |> maybe_put("auth_type", list_param(params, :auth_types))
  end

  defp normalize_params(params) when is_map(params), do: params
  defp normalize_params(_params), do: %{}

  defp list_param(params, key) do
    params
    |> fetch_value(key)
    |> List.wrap()
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp fetch_value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch_value(_map, _key), do: nil

  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalize_string()
  end

  defp normalize_string(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> normalize_string()
  end

  defp normalize_string(value) when is_float(value) do
    value
    |> to_string()
    |> normalize_string()
  end

  defp normalize_string(_value), do: nil
end
