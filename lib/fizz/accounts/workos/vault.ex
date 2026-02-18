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
  @vault_name_max_length 255

  @spec create_object(Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_object(%Scope{} = scope, organization_id, attrs)
      when is_binary(organization_id) and is_map(attrs) do
    with {:ok, resolved_scope} <- resolve_organization_scope(scope, organization_id),
         {:ok, context} <- context_for_scope(resolved_scope) do
      params =
        attrs
        |> Map.take([:name, "name", :value, "value"])
        |> normalize_params()
        |> Map.put(:key_context, context)

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
    with {:ok, _resolved_scope} <- resolve_organization_scope(scope, organization_id) do
      WorkOS.read_vault_object_by_name(name)
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
        |> Map.take([
          :limit,
          "limit",
          :before,
          "before",
          :after,
          "after",
          :updatedAfter,
          "updatedAfter",
          :updated_after,
          "updated_after"
        ])
        |> normalize_params()

      case WorkOS.list_vault_objects(query) do
        {:ok, response} -> {:ok, filter_objects_by_context(response, context)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec object_name(String.t(), String.t() | nil) :: String.t()
  def object_name(display_name, unique_suffix \\ nil) when is_binary(display_name) do
    base =
      display_name
      |> sanitize_component()
      |> default_name_if_blank()

    suffix = normalize_suffix(unique_suffix) || random_suffix()
    max_base_length = max(@vault_name_max_length - byte_size(suffix) - 1, 1)
    truncated_base = String.slice(base, 0, max_base_length)

    "#{truncated_base}_#{suffix}"
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

  defp normalize_params(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) ->
        put_supported_key(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        case key do
          "name" -> Map.put(acc, :name, value)
          "value" -> Map.put(acc, :value, value)
          "key_context" -> Map.put(acc, :key_context, value)
          "version_check" -> Map.put(acc, :version_check, value)
          "limit" -> Map.put(acc, :limit, value)
          "before" -> Map.put(acc, :before, value)
          "after" -> Map.put(acc, :after, value)
          "updatedAfter" -> Map.put(acc, :updatedAfter, value)
          "updated_after" -> Map.put(acc, :updatedAfter, value)
          _ -> acc
        end

      _, acc ->
        acc
    end)
  end

  defp put_supported_key(acc, key, value)
       when key in [:name, :value, :key_context, :version_check],
       do: Map.put(acc, key, value)

  defp put_supported_key(acc, key, value) when key in [:limit, :before, :after, :updatedAfter],
    do: Map.put(acc, key, value)

  defp put_supported_key(acc, _key, _value), do: acc

  defp filter_objects_by_context(%{"data" => objects} = response, context)
       when is_list(objects) do
    filtered =
      Enum.filter(objects, fn object ->
        object_context_matches?(object, context)
      end)

    Map.put(response, "data", filtered)
  end

  defp filter_objects_by_context(response, _context), do: response

  defp object_context_matches?(object, context) when is_map(object) and is_map(context) do
    metadata = object["metadata"] || object[:metadata]
    object_context = metadata && (metadata["context"] || metadata[:context])

    if is_map(object_context) do
      normalized_object_context =
        Map.new(object_context, fn {key, value} -> {to_string(key), value} end)

      Enum.all?(context, fn {key, value} ->
        Map.get(normalized_object_context, to_string(key)) == value
      end)
    else
      false
    end
  end

  defp object_context_matches?(_object, _context), do: false

  defp default_name_if_blank(""), do: "credential"
  defp default_name_if_blank(value), do: value

  defp normalize_suffix(value) when is_binary(value) do
    sanitized =
      value
      |> sanitize_component()
      |> String.slice(0, 24)

    if sanitized == "", do: nil, else: sanitized
  end

  defp normalize_suffix(_value), do: nil

  defp random_suffix do
    Ecto.UUID.generate()
    |> String.replace("-", "")
    |> String.slice(0, 12)
  end

  defp sanitize_component(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end
end
