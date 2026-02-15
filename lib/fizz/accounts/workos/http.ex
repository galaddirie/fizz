defmodule Fizz.Accounts.WorkOS.Http do
  @moduledoc """
  Low-level authenticated HTTP client for the WorkOS API.
  """

  require Logger

  @doc """
  Performs an authenticated HTTP request against the WorkOS API.
  """
  def api_request(method, path, opts) do
    req_opts =
      [
        base_url: WorkOS.base_url(),
        method: method,
        url: path,
        headers: [
          {"authorization", "Bearer #{WorkOS.api_key()}"},
          {"accept", "application/json"}
        ],
        params: normalize_query(opts[:query])
      ]
      |> maybe_put_json(opts[:json])

    case http_client_module().request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status >= 200 and status < 300 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, normalize_http_error(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in [RuntimeError, WorkOS.ApiKeyMissingError, WorkOS.ClientIdMissingError] ->
      Logger.error("WorkOS API request configuration error: #{Exception.message(error)}")
      {:error, :workos_not_configured}
  end

  @doc """
  Removes nil values from a map.
  """
  def compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def normalize_error(%WorkOS.Error{code: code, message: message}) when is_binary(code) do
    {:workos_error, code, message}
  end

  def normalize_error(%WorkOS.Error{message: message}) when is_binary(message),
    do: {:workos_error, message}

  def normalize_error(error), do: error

  def log_error(operation, error) do
    Logger.error("WorkOS #{operation} failed: #{inspect(error)}")
  end

  defp normalize_http_error(status, %{"code" => code, "message" => message})
       when is_binary(code) and is_binary(message) do
    {:workos_error, code, message, status}
  end

  defp normalize_http_error(status, %{"message" => message}) when is_binary(message) do
    {:workos_http_error, status, message}
  end

  defp normalize_http_error(status, body), do: {:workos_http_error, status, body}

  defp maybe_put_json(opts, nil), do: opts

  defp maybe_put_json(opts, json) when is_map(json) do
    compacted_json = compact_map(json)

    if map_size(compacted_json) == 0 do
      opts
    else
      Keyword.put(opts, :json, compacted_json)
    end
  end

  defp maybe_put_json(opts, _json), do: opts

  defp normalize_query(nil), do: []

  defp normalize_query(query) when is_map(query) do
    query
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp normalize_query(query) when is_list(query) do
    Enum.reject(query, fn {_key, value} -> is_nil(value) end)
  end

  defp normalize_query(_query), do: []

  defp http_client_module do
    Application.get_env(:fizz, :workos_http_client_module, Req)
  end
end
