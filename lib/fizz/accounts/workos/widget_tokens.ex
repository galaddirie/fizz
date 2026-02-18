defmodule Fizz.Accounts.WorkOS.WidgetTokens do
  @moduledoc """
  WorkOS widget token operations.
  """

  import Fizz.Accounts.WorkOS.Helpers
  import Fizz.Accounts.WorkOS.Http

  @doc """
  Generates a WorkOS widget token.
  """
  @spec generate_widget_token(map()) :: {:ok, String.t()} | {:error, term()}
  def generate_widget_token(params) when is_map(params) do
    body =
      compact_map(%{
        organization_id:
          read_value(params, [
            :organization_id,
            "organization_id",
            :organizationId,
            "organizationId"
          ]),
        user_id: read_value(params, [:user_id, "user_id", :userId, "userId"]),
        scopes: normalize_widget_scopes(read_value(params, [:scopes, "scopes"]))
      })

    case api_request(:post, "/widgets/token", json: body) do
      {:ok, response} ->
        case read_value(response, [:token, "token"]) do
          token when is_binary(token) ->
            {:ok, token}

          _ ->
            {:error, :invalid_widget_token_response}
        end

      {:error, error} ->
        log_error("generate widget token", error)
        {:error, normalize_error(error)}
    end
  end

  defp normalize_widget_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_widget_scopes(_scopes), do: nil
end
