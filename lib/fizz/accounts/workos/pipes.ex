defmodule Fizz.Accounts.WorkOS.Pipes do
  @moduledoc """
  WorkOS Pipes provider token operations.
  """

  import Fizz.Accounts.WorkOS.Helpers
  import Fizz.Accounts.WorkOS.Http

  @doc """
  Fetches an access token for a Pipes provider connection.
  """
  @spec get_pipes_access_token(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def get_pipes_access_token(provider, user_id, organization_id \\ nil)
      when is_binary(provider) and is_binary(user_id) do
    path = "/data-integrations/#{URI.encode_www_form(provider)}/token"
    body = compact_map(%{user_id: user_id, organization_id: organization_id})

    case api_request(:post, path, json: body) do
      {:ok, response} ->
        {:ok, normalize_pipes_access_token_response(response)}

      {:error, error} ->
        log_error("get pipes access token", error)
        {:error, normalize_error(error)}
    end
  end

  defp normalize_pipes_access_token_response(response) do
    access_token_payload = read_value(response, [:access_token, "access_token"])
    provider_error = read_value(response, [:error, "error"]) |> normalize_pipes_error_code()

    {token, expires_at, scopes, missing_scopes} =
      case access_token_payload do
        %{} = payload ->
          {
            read_value(payload, [:access_token, "access_token"]),
            read_value(payload, [:expires_at, "expires_at"]),
            normalize_string_list(read_value(payload, [:scopes, "scopes"])),
            normalize_string_list(read_value(payload, [:missing_scopes, "missing_scopes"]))
          }

        _ ->
          {nil, nil, [], []}
      end

    active = read_value(response, [:active, "active"]) in [true, "true"]

    %{
      active: active,
      access_token: token,
      expires_at: expires_at,
      scopes: scopes,
      missing_scopes: missing_scopes,
      error: provider_error
    }
  end

  defp normalize_string_list(value) when is_list(value) do
    Enum.filter(value, &is_binary/1)
  end

  defp normalize_string_list(_value), do: []

  defp normalize_pipes_error_code(nil), do: nil
  defp normalize_pipes_error_code("not_installed"), do: :not_installed
  defp normalize_pipes_error_code("needs_reauthorization"), do: :needs_reauthorization
  defp normalize_pipes_error_code(value) when is_binary(value), do: value
  defp normalize_pipes_error_code(value), do: value
end
