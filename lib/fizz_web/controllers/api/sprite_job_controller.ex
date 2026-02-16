defmodule FizzWeb.Api.SpriteJobController do
  use FizzWeb, :controller

  alias Fizz.Sprites
  alias FizzWeb.Api.Helpers

  plug FizzWeb.Plugs.RequireWorkspaceScope

  def create(conn, %{"workspace_id" => workspace_id, "sprite_id" => sprite_id} = params) do
    case Sprites.enqueue_job(conn.assigns.current_scope, workspace_id, sprite_id, params) do
      {:ok, job} ->
        conn
        |> put_status(:created)
        |> json(%{data: Helpers.job_json(job)})

      {:error, reason} ->
        Helpers.error(conn, reason)
    end
  end

  def show(conn, %{"workspace_id" => workspace_id, "sprite_id" => sprite_id, "job_id" => job_id}) do
    case Sprites.get_job(conn.assigns.current_scope, workspace_id, sprite_id, job_id) do
      {:ok, job} -> json(conn, %{data: Helpers.job_json(job)})
      {:error, reason} -> Helpers.error(conn, reason)
    end
  end

  def logs(
        conn,
        %{"workspace_id" => workspace_id, "sprite_id" => sprite_id, "job_id" => job_id} = params
      ) do
    after_seq = parse_integer(params["after_seq"], 0)
    limit = parse_integer(params["limit"], 200)

    case Sprites.list_job_logs(
           conn.assigns.current_scope,
           workspace_id,
           sprite_id,
           job_id,
           after_seq,
           limit
         ) do
      {:ok, chunks} ->
        json(conn, %{data: Enum.map(chunks, &Helpers.log_chunk_json/1)})

      {:error, reason} ->
        Helpers.error(conn, reason)
    end
  end

  def cancel(conn, %{"workspace_id" => workspace_id, "sprite_id" => sprite_id, "job_id" => job_id}) do
    case Sprites.cancel_job(conn.assigns.current_scope, workspace_id, sprite_id, job_id) do
      {:ok, job} -> json(conn, %{data: Helpers.job_json(job)})
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
