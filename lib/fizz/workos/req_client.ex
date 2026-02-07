defmodule Fizz.WorkOS.ReqClient do
  @moduledoc """
  WorkOS SDK HTTP adapter implemented with Req.
  """

  @behaviour WorkOS.Client

  @impl true
  def request(client, opts) do
    opts = Keyword.take(opts, [:method, :url, :query, :headers, :body, :opts])
    transport_opts = Keyword.get(opts, :opts, [])
    access_token = Keyword.get(transport_opts, :access_token, client.api_key)

    path =
      opts
      |> Keyword.fetch!(:url)
      |> interpolate_path(Keyword.get(transport_opts, :path_params, []))

    req_opts =
      [
        base_url: client.base_url,
        method: Keyword.fetch!(opts, :method),
        url: path,
        headers: authorization_header(access_token) ++ normalize_headers(opts[:headers]),
        params: normalize_query(opts[:query])
      ]
      |> maybe_put_json(Keyword.get(opts, :body, %{}))

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_json(opts, body) when body in [%{}, nil], do: opts
  defp maybe_put_json(opts, body), do: Keyword.put(opts, :json, body)

  defp authorization_header(access_token), do: [{"authorization", "Bearer #{access_token}"}]

  defp normalize_headers(nil), do: []

  defp normalize_headers(headers) do
    headers
    |> Enum.reject(fn
      {_key, nil} -> true
      _ -> false
    end)
  end

  defp normalize_query(nil), do: []

  defp normalize_query(query) do
    query
    |> Enum.reject(fn
      {_key, nil} -> true
      _ -> false
    end)
  end

  defp interpolate_path(path, path_params) do
    Enum.reduce(path_params, path, fn {name, value}, acc ->
      String.replace(acc, ":#{name}", URI.encode_www_form(to_string(value)))
    end)
  end
end
