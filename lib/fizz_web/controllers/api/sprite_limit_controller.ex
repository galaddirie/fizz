defmodule FizzWeb.Api.SpriteLimitController do
  use FizzWeb, :controller

  alias Fizz.Sprites
  alias FizzWeb.Api.Helpers

  plug FizzWeb.Plugs.RequireWorkspaceScope

  def show(conn, %{"workspace_id" => workspace_id}) do
    case Sprites.get_limits(conn.assigns.current_scope, workspace_id) do
      {:ok, nil} -> json(conn, %{data: nil})
      {:ok, limits} -> json(conn, %{data: Helpers.limits_json(limits)})
      {:error, reason} -> Helpers.error(conn, reason)
    end
  end

  def update(conn, %{"workspace_id" => workspace_id} = params) do
    case Sprites.update_limits(conn.assigns.current_scope, workspace_id, params) do
      {:ok, limits} -> json(conn, %{data: Helpers.limits_json(limits)})
      {:error, reason} -> Helpers.error(conn, reason)
    end
  end

  def usage(conn, %{"workspace_id" => workspace_id} = params) do
    days = parse_integer(params["days"], 30)

    case Sprites.get_usage(conn.assigns.current_scope, workspace_id, days: days) do
      {:ok, usage} -> json(conn, %{data: usage})
      {:error, reason} -> Helpers.error(conn, reason)
    end
  end

  defp parse_integer(nil, fallback), do: fallback

  defp parse_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> fallback
    end
  end

  defp parse_integer(_value, fallback), do: fallback
end
