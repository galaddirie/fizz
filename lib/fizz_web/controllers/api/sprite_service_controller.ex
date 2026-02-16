defmodule FizzWeb.Api.SpriteServiceController do
  use FizzWeb, :controller

  alias Fizz.Sprites
  alias FizzWeb.Api.Helpers

  plug FizzWeb.Plugs.RequireWorkspaceScope

  def show(conn, %{
        "workspace_id" => workspace_id,
        "sprite_id" => sprite_id,
        "service_name" => service_name
      }) do
    case Sprites.get_service(conn.assigns.current_scope, workspace_id, sprite_id, service_name) do
      {:ok, service} -> json(conn, %{data: Helpers.service_json(service)})
      {:error, reason} -> Helpers.error(conn, reason)
    end
  end

  def upsert(
        conn,
        %{
          "workspace_id" => workspace_id,
          "sprite_id" => sprite_id,
          "service_name" => service_name
        } = params
      ) do
    case Sprites.upsert_service(
           conn.assigns.current_scope,
           workspace_id,
           sprite_id,
           service_name,
           params
         ) do
      {:ok, service} -> json(conn, %{data: Helpers.service_json(service)})
      {:error, reason} -> Helpers.error(conn, reason)
    end
  end

  def start(conn, %{
        "workspace_id" => workspace_id,
        "sprite_id" => sprite_id,
        "service_name" => service_name
      }) do
    case Sprites.start_service(conn.assigns.current_scope, workspace_id, sprite_id, service_name) do
      {:ok, service} -> json(conn, %{data: Helpers.service_json(service)})
      {:error, reason} -> Helpers.error(conn, reason)
    end
  end

  def stop(conn, %{
        "workspace_id" => workspace_id,
        "sprite_id" => sprite_id,
        "service_name" => service_name
      }) do
    case Sprites.stop_service(conn.assigns.current_scope, workspace_id, sprite_id, service_name) do
      {:ok, service} -> json(conn, %{data: Helpers.service_json(service)})
      {:error, reason} -> Helpers.error(conn, reason)
    end
  end

  def logs(
        conn,
        %{
          "workspace_id" => workspace_id,
          "sprite_id" => sprite_id,
          "service_name" => service_name
        } = params
      ) do
    tail =
      parse_integer(
        params["tail"],
        Application.get_env(:fizz, :sprites_service_log_tail_lines, 200)
      )

    case Sprites.service_logs(
           conn.assigns.current_scope,
           workspace_id,
           sprite_id,
           service_name,
           tail: tail
         ) do
      {:ok, logs} -> json(conn, %{data: logs})
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
