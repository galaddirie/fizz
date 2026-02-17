defmodule Fizz.Sprites.Http do
  @moduledoc """
  Direct Req-based access to Sprites HTTP endpoints not surfaced via sprites-ex.
  """

  alias Fizz.Sprites.Client

  @type response :: {:ok, map()} | {:ok, list()} | {:error, term()}

  @spec list_services(String.t()) :: response()
  def list_services(remote_name) do
    request(:get, "/v1/sprites/#{URI.encode_www_form(remote_name)}/services")
  end

  @spec get_service(String.t(), String.t()) :: response()
  def get_service(remote_name, service_name) do
    request(
      :get,
      "/v1/sprites/#{URI.encode_www_form(remote_name)}/services/#{URI.encode_www_form(service_name)}"
    )
  end

  @spec put_service(String.t(), String.t(), map()) :: response()
  def put_service(remote_name, service_name, body) when is_map(body) do
    request(
      :put,
      "/v1/sprites/#{URI.encode_www_form(remote_name)}/services/#{URI.encode_www_form(service_name)}",
      json: body
    )
  end

  @spec start_service(String.t(), String.t()) :: response()
  def start_service(remote_name, service_name) do
    request(
      :post,
      "/v1/sprites/#{URI.encode_www_form(remote_name)}/services/#{URI.encode_www_form(service_name)}/start"
    )
  end

  @spec stop_service(String.t(), String.t()) :: response()
  def stop_service(remote_name, service_name) do
    request(
      :post,
      "/v1/sprites/#{URI.encode_www_form(remote_name)}/services/#{URI.encode_www_form(service_name)}/stop"
    )
  end

  @spec service_logs(String.t(), String.t(), keyword()) :: response()
  def service_logs(remote_name, service_name, opts \\ []) do
    request(
      :get,
      "/v1/sprites/#{URI.encode_www_form(remote_name)}/services/#{URI.encode_www_form(service_name)}/logs",
      query: [tail: Keyword.get(opts, :tail, Client.service_log_tail_lines())]
    )
  end

  @spec list_exec_sessions(String.t()) :: response()
  def list_exec_sessions(remote_name) do
    request(:get, "/v1/sprites/#{URI.encode_www_form(remote_name)}/exec")
  end

  @spec kill_exec_session(String.t(), String.t(), String.t()) :: response()
  def kill_exec_session(remote_name, session_id, signal \\ "SIGTERM") do
    request(
      :post,
      "/v1/sprites/#{URI.encode_www_form(remote_name)}/exec/#{URI.encode_www_form(session_id)}/kill",
      query: [signal: signal]
    )
  end

  @spec update_sprite_url_settings(String.t(), map()) :: response()
  def update_sprite_url_settings(remote_name, settings) when is_map(settings) do
    request(
      :put,
      "/v1/sprites/#{URI.encode_www_form(remote_name)}",
      json: %{url_settings: settings}
    )
  end

  @spec request(atom(), String.t(), keyword()) :: response()
  def request(method, path, opts \\ []) do
    with token when is_binary(token) <- Client.api_key() do
      req_opts =
        [
          base_url: Client.base_url(),
          method: method,
          url: path,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"accept", "application/json"}
          ],
          params: normalize_query(opts[:query])
        ]
        |> maybe_put_json(opts[:json])

      case Req.request(req_opts) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, normalize_api_error(status, body)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:error, :sprites_not_configured}
    end
  end

  defp normalize_query(nil), do: []

  defp normalize_query(query) when is_list(query) do
    Enum.reject(query, fn {_key, value} -> is_nil(value) end)
  end

  defp normalize_query(query) when is_map(query) do
    query
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp normalize_query(_query), do: []

  defp maybe_put_json(opts, nil), do: opts
  defp maybe_put_json(opts, json) when is_map(json), do: Keyword.put(opts, :json, json)
  defp maybe_put_json(opts, _json), do: opts

  defp normalize_api_error(status, %{"error" => code, "message" => message}) do
    %{
      status: status,
      code: code,
      message: message,
      retry_after_seconds: nil
    }
  end

  defp normalize_api_error(status, %{"message" => message}) do
    %{status: status, code: nil, message: message, retry_after_seconds: nil}
  end

  defp normalize_api_error(status, body) do
    %{status: status, code: nil, message: inspect(body), retry_after_seconds: nil}
  end
end
