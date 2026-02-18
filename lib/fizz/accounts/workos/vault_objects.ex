defmodule Fizz.Accounts.WorkOS.VaultObjects do
  @moduledoc """
  Direct WorkOS Vault object API operations.
  """

  import Fizz.Accounts.WorkOS.Helpers
  import Fizz.Accounts.WorkOS.Http

  @doc """
  Creates a Vault object.
  """
  @spec create_vault_object(map()) :: {:ok, map()} | {:error, term()}
  def create_vault_object(params) when is_map(params) do
    body =
      compact_map(%{
        name: read_value(params, [:name, "name"]),
        value: read_value(params, [:value, "value"]),
        context: normalize_vault_context(read_value(params, [:context, "context"]))
      })

    case api_request(:post, "/vault/objects", json: body) do
      {:ok, response} ->
        {:ok, response}

      {:error, error} ->
        log_error("create vault object", error)
        {:error, normalize_error(error)}
    end
  end

  @doc """
  Reads a Vault object by ID.
  """
  @spec read_vault_object(String.t()) :: {:ok, map()} | {:error, term()}
  def read_vault_object(object_id) when is_binary(object_id) do
    path = "/vault/objects/#{URI.encode_www_form(object_id)}"

    case api_request(:get, path, []) do
      {:ok, response} ->
        {:ok, response}

      {:error, error} ->
        log_error("read vault object", error)
        {:error, normalize_error(error)}
    end
  end

  @doc """
  Reads a Vault object by name using list filtering.
  """
  @spec read_vault_object_by_name(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def read_vault_object_by_name(name, opts \\ %{}) when is_binary(name) and is_map(opts) do
    query =
      opts
      |> Map.take([:context, "context", :limit, "limit", :order, "order", :after, "after"])
      |> Map.put_new(:limit, 100)

    with {:ok, %{"data" => objects}} <- list_vault_objects(query),
         %{} = object <- Enum.find(objects, &(Map.get(&1, "name") == name)),
         object_id when is_binary(object_id) <- Map.get(object, "id") do
      read_vault_object(object_id)
    else
      nil -> {:error, :vault_object_not_found}
      {:ok, _response} -> {:error, :vault_object_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :vault_object_not_found}
    end
  end

  @doc """
  Lists Vault objects.
  """
  @spec list_vault_objects(map()) :: {:ok, map()} | {:error, term()}
  def list_vault_objects(query \\ %{}) when is_map(query) do
    list_query =
      compact_map(%{
        limit: read_value(query, [:limit, "limit"]),
        before: read_value(query, [:before, "before"]),
        after: read_value(query, [:after, "after"]),
        order: read_value(query, [:order, "order"]),
        context: normalize_vault_context(read_value(query, [:context, "context"]))
      })

    case api_request(:get, "/vault/objects", query: list_query) do
      {:ok, response} ->
        {:ok, response}

      {:error, error} ->
        log_error("list vault objects", error)
        {:error, normalize_error(error)}
    end
  end

  @doc """
  Updates a Vault object by ID.
  """
  @spec update_vault_object(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_vault_object(object_id, params) when is_binary(object_id) and is_map(params) do
    path = "/vault/objects/#{URI.encode_www_form(object_id)}"

    body =
      compact_map(%{
        value: read_value(params, [:value, "value"]),
        version_check:
          normalize_vault_version_check(read_value(params, [:version_check, "version_check"]))
      })

    case api_request(:patch, path, json: body) do
      {:ok, response} ->
        {:ok, response}

      {:error, error} ->
        log_error("update vault object", error)
        {:error, normalize_error(error)}
    end
  end

  @doc """
  Deletes a Vault object.
  """
  @spec delete_vault_object(String.t(), map()) :: :ok | {:error, term()}
  def delete_vault_object(object_id, params \\ %{})

  def delete_vault_object(object_id, params) when is_binary(object_id) and is_map(params) do
    path = "/vault/objects/#{URI.encode_www_form(object_id)}"

    body =
      compact_map(%{
        version_check:
          normalize_vault_version_check(read_value(params, [:version_check, "version_check"]))
      })

    request_opts =
      if map_size(body) == 0 do
        []
      else
        [json: body]
      end

    case api_request(:delete, path, request_opts) do
      {:ok, _response} ->
        :ok

      {:error, error} ->
        log_error("delete vault object", error)
        {:error, normalize_error(error)}
    end
  end

  defp normalize_vault_context(context) when is_map(context), do: context
  defp normalize_vault_context(_context), do: nil

  defp normalize_vault_version_check(nil), do: nil

  defp normalize_vault_version_check(version_check) when is_binary(version_check),
    do: String.trim(version_check)

  defp normalize_vault_version_check(_version_check), do: nil
end
