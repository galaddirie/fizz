defmodule Fizz.Slots.Resolvers.Credential do
  @moduledoc """
  Slot resolver for the `"credential"` kind.

  Spec shape:

      %{"provider" => "github_oauth", "auth_type" => "oauth"}

  Binding data shape (what a user picks):

      %{"credential_id" => "<api_credential or oauth_connection id>"}

  At runtime, `resolve/3` returns a credential_ref-shaped map keyed to the
  actor user. Executors continue calling
  `Fizz.Integrations.resolve_auth_for_execution/4` with that map to fetch
  the actual token. This keeps token I/O out of slot resolution and avoids
  changing every executor.
  """

  @behaviour Fizz.Slots.Resolver

  alias Fizz.Accounts.{ExternalAuth, Scope}

  @max_options 50

  @impl true
  def resolve(spec, binding_data, %Scope{user: %{id: user_id}})
      when is_map(spec) and is_map(binding_data) and is_binary(user_id) do
    with {:ok, provider} <- fetch_string(spec, "provider"),
         {:ok, auth_type} <- fetch_string(spec, "auth_type"),
         {:ok, credential_id} <- fetch_string(binding_data, "credential_id") do
      {:ok,
       %{
         "id" => credential_id,
         "provider" => provider,
         "auth_type" => auth_type,
         "owner_user_id" => user_id
       }}
    end
  end

  def resolve(spec, binding_data, %Scope{})
      when is_map(spec) and is_map(binding_data) do
    with {:ok, owner_user_id} <- fetch_string(binding_data, "owner_user_id"),
         {:ok, provider} <- fetch_string(spec, "provider"),
         {:ok, auth_type} <- fetch_string(spec, "auth_type"),
         {:ok, credential_id} <- fetch_string(binding_data, "credential_id") do
      {:ok,
       %{
         "id" => credential_id,
         "provider" => provider,
         "auth_type" => auth_type,
         "owner_user_id" => owner_user_id
       }}
    end
  end

  def resolve(_spec, _binding_data, _scope), do: {:error, :invalid_slot_resolution_args}

  @impl true
  def validate_spec(spec) when is_map(spec) do
    with {:ok, _provider} <- fetch_string(spec, "provider"),
         {:ok, auth_type} <- fetch_string(spec, "auth_type"),
         true <- auth_type in ["api_key", "oauth"] do
      :ok
    else
      false -> {:error, :invalid_auth_type}
      {:error, _reason} = error -> error
    end
  end

  def validate_spec(_spec), do: {:error, :invalid_spec}

  @impl true
  def validate_binding_data(%{"credential_id" => credential_id}) when is_binary(credential_id) do
    case String.trim(credential_id) do
      "" -> {:error, :credential_id_required}
      _ -> :ok
    end
  end

  def validate_binding_data(_), do: {:error, :credential_id_required}

  @impl true
  def validate_binding_data(binding_data, spec) when is_map(binding_data) and is_map(spec) do
    with :ok <- validate_spec(spec),
         :ok <- validate_binding_data(binding_data) do
      :ok
    end
  end

  def validate_binding_data(_binding_data, _spec), do: {:error, :credential_id_required}

  @impl true
  def validate_binding_data(binding_data, spec, %Scope{} = scope)
      when is_map(binding_data) and is_map(spec) do
    with :ok <- validate_binding_data(binding_data, spec),
         {:ok, credential_id} <- fetch_string(binding_data, "credential_id"),
         {:ok, options} <- options_for_spec(spec, scope, limit: :all),
         true <- credential_option_available?(options, credential_id) do
      :ok
    else
      false -> {:error, :credential_not_available}
      {:error, _reason} = error -> error
    end
  end

  def validate_binding_data(binding_data, spec, _scope),
    do: validate_binding_data(binding_data, spec)

  @impl true
  def candidate_options(spec, %Scope{} = scope) when is_map(spec) do
    options_for_spec(spec, scope)
  end

  def candidate_options(_spec, _scope), do: {:error, :invalid_scope}

  @doc """
  Returns credential slot options with optional query filtering and result cap.
  """
  @spec options_for_spec(map(), Scope.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def options_for_spec(spec, scope, opts \\ [])

  def options_for_spec(spec, %Scope{} = scope, opts) when is_map(spec) and is_list(opts) do
    with {:ok, organization_id} <- fetch_organization_id(scope) do
      external_auth_opts =
        []
        |> maybe_put(:provider_filter, list_param(spec, "provider"))
        |> maybe_put(:auth_types, list_param(spec, "auth_type"))

      case ExternalAuth.list_credential_options(scope, organization_id, external_auth_opts) do
        {:ok, options} ->
          options =
            options
            |> filter_to_current_user(scope_user_id(scope))
            |> apply_search(Keyword.get(opts, :q, ""))
            |> apply_limit(Keyword.get(opts, :limit, @max_options))

          {:ok, options}

        {:error, _} = error ->
          error
      end
    end
  end

  def options_for_spec(_spec, _scope, _opts), do: {:error, :invalid_scope}

  defp credential_option_available?(options, credential_id) when is_list(options) do
    Enum.any?(options, fn option ->
      fetch_value(option, "id") == credential_id
    end)
  end

  defp apply_limit(options, :all), do: options

  defp apply_limit(options, limit) when is_integer(limit) and limit >= 0,
    do: Enum.take(options, limit)

  defp apply_limit(options, _limit), do: Enum.take(options, @max_options)

  defp filter_to_current_user(options, user_id) when is_binary(user_id) do
    Enum.filter(options, fn option ->
      option_user_id = Map.get(option, :owner_user_id) || Map.get(option, "owner_user_id")
      option_user_id == user_id
    end)
  end

  defp filter_to_current_user(options, _user_id), do: options

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
      fetch_value(option, "display_name"),
      fetch_value(option, "provider_label"),
      fetch_value(option, "provider"),
      fetch_value(option, "auth_type"),
      fetch_value(option, "owner_display_name"),
      fetch_value(option, "id")
    ]
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp fetch_string(map, key) when is_map(map) and is_binary(key) do
    case fetch_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_field, key}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:missing_field, key}}
    end
  end

  defp fetch_organization_id(%Scope{organization_id: organization_id})
       when is_binary(organization_id) and organization_id != "",
       do: {:ok, organization_id}

  defp fetch_organization_id(_scope), do: {:error, :organization_scope_required}

  defp list_param(spec, key) do
    case fetch_value(spec, key) do
      nil -> []
      value when is_binary(value) -> [value]
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _ -> []
    end
  end

  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp scope_user_id(%Scope{user: %{id: user_id}}) when is_binary(user_id), do: user_id
  defp scope_user_id(%Scope{}), do: nil

  defp fetch_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

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
