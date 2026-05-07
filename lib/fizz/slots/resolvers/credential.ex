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

  def resolve(_spec, _binding_data, _scope), do: {:error, :invalid_slot_resolution_args}

  @impl true
  def validate_binding_data(%{"credential_id" => credential_id}) when is_binary(credential_id) do
    case String.trim(credential_id) do
      "" -> {:error, :credential_id_required}
      _ -> :ok
    end
  end

  def validate_binding_data(_), do: {:error, :credential_id_required}

  @impl true
  def candidate_options(spec, %Scope{} = scope) when is_map(spec) do
    with {:ok, organization_id} <- fetch_organization_id(scope) do
      opts =
        []
        |> maybe_put(:provider_filter, list_param(spec, "provider"))
        |> maybe_put(:auth_types, list_param(spec, "auth_type"))

      case ExternalAuth.list_credential_options(scope, organization_id, opts) do
        {:ok, options} -> {:ok, filter_to_current_user(options, scope.user.id)}
        {:error, _} = error -> error
      end
    end
  end

  def candidate_options(_spec, _scope), do: {:error, :invalid_scope}

  defp filter_to_current_user(options, user_id) when is_binary(user_id) do
    Enum.filter(options, fn option ->
      option_user_id = Map.get(option, :owner_user_id) || Map.get(option, "owner_user_id")
      option_user_id == user_id
    end)
  end

  defp filter_to_current_user(options, _user_id), do: options

  defp fetch_string(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_field, key}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:missing_field, key}}
    end
  rescue
    ArgumentError -> {:error, {:missing_field, key}}
  end

  defp fetch_organization_id(%Scope{organization_id: organization_id})
       when is_binary(organization_id) and organization_id != "",
       do: {:ok, organization_id}

  defp fetch_organization_id(_scope), do: {:error, :organization_scope_required}

  defp list_param(spec, key) do
    case Map.get(spec, key) || Map.get(spec, String.to_atom(key)) do
      nil -> []
      value when is_binary(value) -> [value]
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _ -> []
    end
  rescue
    ArgumentError -> []
  end

  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
