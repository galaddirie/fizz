defmodule FizzWeb.Api.Helpers do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller

  alias Ecto.Changeset

  alias Fizz.Sprites.{
    ConsoleSession,
    ExecJob,
    ExecLogChunk,
    Service,
    Sprite,
    WorkspaceSpriteLimit
  }

  @spec error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def error(conn, %Changeset{} = changeset) do
    put_status(conn, :unprocessable_entity)
    |> json(%{error: "validation_failed", details: changeset_errors(changeset)})
  end

  def error(conn, {:quota_exceeded, quota}) do
    put_status(conn, :too_many_requests)
    |> json(%{error: "quota_exceeded", quota: to_string(quota)})
  end

  def error(conn, :rate_limited) do
    put_status(conn, :too_many_requests)
    |> json(%{error: "rate_limited"})
  end

  def error(conn, :unauthenticated) do
    put_status(conn, :unauthorized)
    |> json(%{error: "unauthenticated"})
  end

  def error(conn, :forbidden) do
    put_status(conn, :forbidden)
    |> json(%{error: "forbidden"})
  end

  def error(conn, reason)
      when reason in [
             :workspace_not_found,
             :sprite_not_found,
             :job_not_found,
             :console_not_found,
             :service_not_found
           ] do
    put_status(conn, :not_found)
    |> json(%{error: to_string(reason)})
  end

  def error(conn, :sprites_not_configured) do
    put_status(conn, :service_unavailable)
    |> json(%{error: "sprites_not_configured"})
  end

  def error(conn, reason) do
    put_status(conn, :internal_server_error)
    |> json(%{error: "internal_error", reason: inspect(reason)})
  end

  @spec sprite_json(Sprite.t()) :: map()
  def sprite_json(%Sprite{} = sprite) do
    %{
      id: sprite.id,
      workspace_id: sprite.workspace_id,
      name: sprite.name,
      remote_name: sprite.remote_name,
      remote_id: sprite.remote_id,
      status: to_string(sprite.status),
      url: sprite.url,
      url_auth_mode: to_string(sprite.url_auth_mode),
      config: sprite.config,
      metadata: sprite.metadata,
      last_seen_at: sprite.last_seen_at,
      inserted_at: sprite.inserted_at,
      updated_at: sprite.updated_at
    }
  end

  @spec job_json(ExecJob.t()) :: map()
  def job_json(%ExecJob{} = job) do
    %{
      id: job.id,
      sprite_id: job.sprite_id,
      workspace_id: job.workspace_id,
      state: to_string(job.state),
      command: job.command,
      args: job.args,
      dir: job.dir,
      timeout_ms: job.timeout_ms,
      exit_code: job.exit_code,
      remote_session_id: job.remote_session_id,
      bytes_stdout: job.bytes_stdout,
      bytes_stderr: job.bytes_stderr,
      bytes_total: job.bytes_total,
      error_code: job.error_code,
      error_message: job.error_message,
      heartbeat_at: job.heartbeat_at,
      started_at: job.started_at,
      finished_at: job.finished_at,
      inserted_at: job.inserted_at,
      updated_at: job.updated_at
    }
  end

  @spec log_chunk_json(ExecLogChunk.t()) :: map()
  def log_chunk_json(%ExecLogChunk{} = chunk) do
    %{
      seq: chunk.seq,
      stream: to_string(chunk.stream),
      chunk: Base.encode64(chunk.chunk),
      byte_size: chunk.byte_size,
      inserted_at: chunk.inserted_at
    }
  end

  @spec console_json(ConsoleSession.t()) :: map()
  def console_json(%ConsoleSession{} = console_session) do
    %{
      id: console_session.id,
      sprite_id: console_session.sprite_id,
      workspace_id: console_session.workspace_id,
      state: to_string(console_session.state),
      remote_session_id: console_session.remote_session_id,
      opened_at: console_session.opened_at,
      closed_at: console_session.closed_at,
      close_reason: console_session.close_reason,
      rows: console_session.rows,
      cols: console_session.cols,
      inserted_at: console_session.inserted_at,
      updated_at: console_session.updated_at
    }
  end

  @spec service_json(Service.t()) :: map()
  def service_json(%Service{} = service) do
    %{
      id: service.id,
      sprite_id: service.sprite_id,
      workspace_id: service.workspace_id,
      name: service.name,
      cmd: service.cmd,
      args: service.args,
      needs: service.needs,
      status: to_string(service.status),
      published: service.published,
      metadata: service.metadata,
      last_started_at: service.last_started_at,
      last_stopped_at: service.last_stopped_at,
      inserted_at: service.inserted_at,
      updated_at: service.updated_at
    }
  end

  @spec limits_json(WorkspaceSpriteLimit.t()) :: map()
  def limits_json(%WorkspaceSpriteLimit{} = limits) do
    %{
      workspace_id: limits.workspace_id,
      max_sprites: limits.max_sprites,
      max_concurrent_jobs: limits.max_concurrent_jobs,
      max_jobs_per_minute: limits.max_jobs_per_minute,
      max_console_sessions: limits.max_console_sessions,
      max_services_per_sprite: limits.max_services_per_sprite,
      max_checkpoints_per_sprite: limits.max_checkpoints_per_sprite,
      daily_exec_seconds_limit: limits.daily_exec_seconds_limit,
      daily_log_bytes_limit: limits.daily_log_bytes_limit,
      inserted_at: limits.inserted_at,
      updated_at: limits.updated_at
    }
  end

  defp changeset_errors(changeset) do
    Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts
        |> Keyword.get(String.to_existing_atom(key), key)
        |> to_string()
      end)
    end)
  end
end
