defmodule Fizz.Integrations.CredentialsResolver do
  @moduledoc """
  Resolves credential options for workflow step config fields.

  Implements `Fizz.Steps.Resolver` so step executors can reference this module
  directly in their config schema.
  """

  @behaviour Fizz.Steps.Resolver

  alias Fizz.Accounts.Scope
  alias Fizz.Accounts.ExternalAuth, as: AccountExternalAuth

  @max_options 50

  @impl true
  def resolve(%{q: query, params: params, context: context}) do
    with {:ok, scope} <- fetch_scope(context),
         {:ok, organization_id} <- fetch_organization_id(scope),
         {:ok, options} <-
           AccountExternalAuth.list_credential_options(
             scope,
             organization_id,
             build_external_auth_opts(params)
           ) do
      {:ok, options |> apply_search(query) |> Enum.take(@max_options)}
    end
  end

  defp fetch_scope(context) when is_map(context) do
    case fetch_value(context, :current_scope) do
      %Scope{} = scope -> {:ok, scope}
      _ -> {:error, :scope_not_available}
    end
  end

  defp fetch_scope(_context), do: {:error, :scope_not_available}

  defp fetch_organization_id(%Scope{organization_id: organization_id})
       when is_binary(organization_id) and organization_id != "" do
    {:ok, organization_id}
  end

  defp fetch_organization_id(_scope), do: {:error, :organization_scope_required}

  defp build_external_auth_opts(params) do
    params = normalize_params(params)
    provider_filter = provider_filter(params)
    auth_types = auth_types(params)

    []
    |> maybe_put(:provider_filter, provider_filter)
    |> maybe_put(:auth_types, auth_types)
  end

  defp normalize_params(params) when is_map(params), do: params
  defp normalize_params(_params), do: %{}

  defp provider_filter(params) do
    case list_param(params, :provider_filter) do
      [] ->
        case fetch_value(params, :provider) |> normalize_string() do
          nil -> []
          provider -> [provider]
        end

      values ->
        values
    end
  end

  defp auth_types(params) do
    case list_param(params, :auth_types) do
      [] ->
        case fetch_value(params, :auth_type) |> normalize_string() do
          nil -> []
          auth_type -> [auth_type]
        end

      values ->
        values
    end
  end

  defp list_param(params, key) do
    params
    |> fetch_value(key)
    |> List.wrap()
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp apply_search(options, query) do
    case normalize_query(query) do
      nil ->
        options

      query ->
        Enum.filter(options, &matches_query?(&1, query))
    end
  end

  defp matches_query?(option, query) when is_map(option) do
    option
    |> searchable_fields()
    |> Enum.any?(fn value ->
      value
      |> String.downcase()
      |> String.contains?(query)
    end)
  end

  defp matches_query?(_option, _query), do: false

  defp searchable_fields(option) do
    [
      fetch_value(option, :display_name),
      fetch_value(option, :provider_label),
      fetch_value(option, :provider),
      fetch_value(option, :auth_type),
      fetch_value(option, :owner_display_name),
      fetch_value(option, :id)
    ]
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
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

  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_query(query) do
    query
    |> normalize_string()
    |> case do
      nil -> nil
      value -> String.downcase(value)
    end
  end

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
