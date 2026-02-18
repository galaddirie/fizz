defmodule Fizz.Accounts.WorkOS.Vault do
  @moduledoc """
  Organization-scoped wrapper around WorkOS Vault APIs.

  This module keeps tenant boundaries explicit and centralizes
  WorkOS Vault error normalization for higher-level workflows.
  """

  alias Fizz.Accounts
  alias Fizz.Accounts.Scope
  alias Fizz.Accounts.WorkOS

  @type vault_context :: %{required(String.t()) => String.t()}

  @spec create_object(Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_object(%Scope{} = scope, organization_id, attrs)
      when is_binary(organization_id) and is_map(attrs) do
    with {:ok, resolved_scope} <- resolve_organization_scope(scope, organization_id),
         {:ok, context} <- context_for_scope(resolved_scope) do
      params =
        attrs
        |> Map.take([:name, "name", :value, "value"])
        |> normalize_params()
        |> Map.put(:context, context)

      WorkOS.create_vault_object(params)
    end
  end

  @spec read_object(Scope.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read_object(%Scope{} = scope, organization_id, object_id)
      when is_binary(organization_id) and is_binary(object_id) do
    with {:ok, _resolved_scope} <- resolve_organization_scope(scope, organization_id) do
      WorkOS.read_vault_object(object_id)
    end
  end

  @spec read_object_by_name(Scope.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read_object_by_name(%Scope{} = scope, organization_id, name)
      when is_binary(organization_id) and is_binary(name) do
    with {:ok, resolved_scope} <- resolve_organization_scope(scope, organization_id),
         {:ok, context} <- context_for_scope(resolved_scope) do
      WorkOS.read_vault_object_by_name(name, %{context: context})
    end
  end

  @spec update_object(Scope.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_object(%Scope{} = scope, organization_id, object_id, attrs)
      when is_binary(organization_id) and is_binary(object_id) and is_map(attrs) do
    with {:ok, _resolved_scope} <- resolve_organization_scope(scope, organization_id) do
      params =
        attrs
        |> Map.take([:value, "value", :version_check, "version_check"])
        |> normalize_params()

      WorkOS.update_vault_object(object_id, params)
    end
  end

  @spec delete_object(Scope.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def delete_object(%Scope{} = scope, organization_id, object_id, attrs \\ %{})
      when is_binary(organization_id) and is_binary(object_id) and is_map(attrs) do
    with {:ok, _resolved_scope} <- resolve_organization_scope(scope, organization_id) do
      params =
        attrs
        |> Map.take([:version_check, "version_check"])
        |> normalize_params()

      WorkOS.delete_vault_object(object_id, params)
    end
  end

  @spec list_objects(Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def list_objects(%Scope{} = scope, organization_id, opts \\ %{})
      when is_binary(organization_id) and is_map(opts) do
    with {:ok, resolved_scope} <- resolve_organization_scope(scope, organization_id),
         {:ok, context} <- context_for_scope(resolved_scope) do
      query =
        opts
        |> Map.take([:limit, "limit", :before, "before", :after, "after", :order, "order"])
        |> normalize_params()
        |> Map.put(:context, context)

      WorkOS.list_vault_objects(query)
    end
  end

  @spec object_name(String.t(), String.t(), String.t(), String.t() | nil) :: String.t()
  def object_name(organization_id, user_id, provider, suffix \\ nil)
      when is_binary(organization_id) and is_binary(user_id) and is_binary(provider) do
    base =
      [
        "org",
        sanitize_component(organization_id),
        "user",
        sanitize_component(user_id),
        "provider",
        sanitize_component(provider)
      ]
      |> Enum.join("_")

    case suffix do
      value when is_binary(value) ->
        trimmed_value = String.trim(value)

        if byte_size(trimmed_value) > 0 do
          "#{base}_#{sanitize_component(trimmed_value)}"
        else
          base
        end

      _ ->
        base
    end
  end

  @spec context_for_scope(Scope.t()) ::
          {:ok, vault_context()} | {:error, :organization_scope_required}
  def context_for_scope(%Scope{organization_id: org_id, user: user}) when is_binary(org_id) do
    {:ok,
     %{
       "organization_id" => org_id,
       "user_id" => to_string(user.id)
     }}
  end

  def context_for_scope(_scope), do: {:error, :organization_scope_required}

  defp resolve_organization_scope(
         %Scope{organization_id: organization_id} = scope,
         organization_id
       )
       when is_binary(organization_id),
       do: {:ok, scope}

  defp resolve_organization_scope(%Scope{} = scope, organization_id)
       when is_binary(organization_id),
       do: Accounts.build_scope(scope, organization_id)

  defp resolve_organization_scope(_scope, _organization_id),
    do: {:error, :organization_scope_required}

  defp normalize_params(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) ->
        put_supported_key(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        case key do
          "name" -> Map.put(acc, :name, value)
          "value" -> Map.put(acc, :value, value)
          "context" -> Map.put(acc, :context, value)
          "version_check" -> Map.put(acc, :version_check, value)
          "limit" -> Map.put(acc, :limit, value)
          "before" -> Map.put(acc, :before, value)
          "after" -> Map.put(acc, :after, value)
          "order" -> Map.put(acc, :order, value)
          _ -> acc
        end

      _, acc ->
        acc
    end)
  end

  defp put_supported_key(acc, key, value) when key in [:name, :value, :context, :version_check],
    do: Map.put(acc, key, value)

  defp put_supported_key(acc, key, value) when key in [:limit, :before, :after, :order],
    do: Map.put(acc, key, value)

  defp put_supported_key(acc, _key, _value), do: acc

  defp sanitize_component(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end
end
