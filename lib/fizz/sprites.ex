defmodule Fizz.Sprites do
  @moduledoc """
  Workspace-scoped broker context for Sprites lifecycle, jobs, consoles,
  services, checkpoints, quotas, and usage.
  """

  import Ecto.Query

  require Logger

  alias Fizz.Accounts
  alias Fizz.Accounts.Scope
  alias Fizz.Repo

  alias Fizz.Sprites.{
    Checkpoint,
    Client,
    ConsoleSession,
    ExecJob,
    ExecLogChunk,
    Http,
    Quota,
    RateLimiter,
    Service,
    Sprite,
    Usage,
    WorkspaceSpriteLimit
  }

  alias Fizz.Sprites.Workers.ExecJobWorker

  @type error_reason ::
          :forbidden
          | :workspace_not_found
          | :sprite_not_found
          | :job_not_found
          | :console_not_found
          | :unauthenticated
          | :sprites_not_configured
          | {:quota_exceeded, atom()}
          | :rate_limited
          | term()

  @doc """
  Returns workspace-aware scope for the workspace id.
  """
  @spec workspace_scope(Scope.t() | nil, String.t()) ::
          {:ok, Scope.t()} | {:error, error_reason()}
  def workspace_scope(scope, workspace_id) do
    resolve_workspace_scope(scope, workspace_id)
  end

  @doc """
  Lists sprites in the workspace.
  """
  @spec list_sprites(Scope.t() | nil, String.t()) ::
          {:ok, [Sprite.t()]} | {:error, error_reason()}
  def list_sprites(scope, workspace_id) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_read(workspace_scope) do
      sprites =
        from(sprite in Sprite,
          where: sprite.workspace_id == ^workspace_id,
          order_by: [asc: sprite.inserted_at]
        )
        |> Repo.all()

      {:ok, sprites}
    end
  end

  @doc """
  Gets a sprite by id within the workspace.
  """
  @spec get_sprite(Scope.t() | nil, String.t(), String.t()) ::
          {:ok, Sprite.t()} | {:error, error_reason()}
  def get_sprite(scope, workspace_id, sprite_id) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_read(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id) do
      {:ok, sprite}
    end
  end

  @doc """
  Updates mutable sprite fields and optionally URL auth settings remotely.
  """
  @spec update_sprite(Scope.t() | nil, String.t(), String.t(), map()) ::
          {:ok, Sprite.t()} | {:error, error_reason() | Ecto.Changeset.t()}
  def update_sprite(scope, workspace_id, sprite_id, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_manage(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id),
         :ok <- maybe_update_remote_url_auth(sprite, attr(attrs, :url_auth_mode)),
         {:ok, updated_sprite} <-
           sprite
           |> Sprite.changeset(%{
             status: normalize_sprite_status(attr(attrs, :status)),
             url_auth_mode: normalize_url_auth_mode(attr(attrs, :url_auth_mode)),
             metadata: attr(attrs, :metadata) || sprite.metadata,
             config: attr(attrs, :config) || sprite.config
           })
           |> Repo.update() do
      {:ok, updated_sprite}
    end
  end

  @doc """
  Creates a new sprite for the workspace and applies restrictive default egress policy.
  """
  @spec create_sprite(Scope.t() | nil, String.t(), map()) ::
          {:ok, Sprite.t()} | {:error, error_reason()}
  def create_sprite(scope, workspace_id, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_manage(workspace_scope),
         :ok <- Quota.check(workspace_id, :sprites),
         {:ok, _workspace_limit} <- fetch_workspace_limits(workspace_id),
         {:ok, client} <- Client.client(),
         :ok <- RateLimiter.check_and_increment(workspace_id, "sprite_creates", 30),
         name when is_binary(name) <- attr(attrs, :name),
         remote_name <- remote_name_for(workspace_id, name),
         {:ok, remote_sprite} <-
           Sprites.create(client, remote_name, config: attr(attrs, :config) || %{}),
         :ok <- apply_default_network_policy(remote_sprite, attrs),
         {:ok, sprite} <-
           insert_local_sprite(workspace_scope, workspace_id, attrs, remote_name, remote_sprite) do
      Usage.increment(workspace_id, %{sprites_created: 1})
      emit_event([:fizz, :sprites, :sprite, :created], %{count: 1}, %{workspace_id: workspace_id})
      {:ok, sprite}
    else
      nil -> {:error, :invalid_sprite_name}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a sprite remotely and marks it deleted locally.
  """
  @spec delete_sprite(Scope.t() | nil, String.t(), String.t()) ::
          {:ok, Sprite.t()} | {:error, error_reason()}
  def delete_sprite(scope, workspace_id, sprite_id) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_manage(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id),
         {:ok, remote_sprite} <- Client.sprite(sprite.remote_name),
         :ok <- Sprites.destroy(remote_sprite),
         {:ok, updated_sprite} <-
           sprite
           |> Sprite.changeset(%{status: :deleted, deleted_at: DateTime.utc_now()})
           |> Repo.update() do
      Usage.increment(workspace_id, %{sprites_deleted: 1})
      emit_event([:fizz, :sprites, :sprite, :deleted], %{count: 1}, %{workspace_id: workspace_id})
      {:ok, updated_sprite}
    end
  end

  @doc """
  Enqueues a non-interactive execution job.
  """
  @spec enqueue_job(Scope.t() | nil, String.t(), String.t(), map()) ::
          {:ok, ExecJob.t()} | {:error, error_reason()}
  def enqueue_job(scope, workspace_id, sprite_id, exec_spec) when is_map(exec_spec) do
    exec_spec = normalize_attrs(exec_spec)

    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_execute(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id),
         :ok <- Quota.check(workspace_id, :concurrent_jobs),
         {:ok, workspace_limit} <- fetch_workspace_limits(workspace_id),
         :ok <-
           RateLimiter.check_and_increment(
             workspace_id,
             "jobs_per_minute",
             workspace_limit.max_jobs_per_minute
           ),
         command when is_binary(command) <- attr(exec_spec, :command),
         args <- normalize_string_list(attr(exec_spec, :args)),
         timeout_ms <- attr(exec_spec, :timeout_ms) || Client.exec_timeout_ms_default(),
         {:ok, exec_job} <-
           %ExecJob{}
           |> ExecJob.changeset(%{
             sprite_id: sprite.id,
             workspace_id: workspace_id,
             requested_by_user_id: workspace_scope.user.id,
             state: :queued,
             command: command,
             args: args,
             env: normalize_env_map(attr(exec_spec, :env)),
             dir: attr(exec_spec, :dir),
             tty: false,
             timeout_ms: timeout_ms
           })
           |> Repo.insert(),
         {:ok, oban_job} <-
           %{"exec_job_id" => exec_job.id}
           |> ExecJobWorker.new(queue: :sprites)
           |> Oban.insert(),
         {:ok, exec_job} <-
           exec_job
           |> ExecJob.changeset(%{oban_job_id: oban_job.id})
           |> Repo.update() do
      Usage.increment(workspace_id, %{jobs_total: 1})
      emit_event([:fizz, :sprites, :job, :queued], %{count: 1}, %{workspace_id: workspace_id})
      {:ok, exec_job}
    else
      nil ->
        {:error, :invalid_command}

      {:error, {:quota_exceeded, _} = quota_error} ->
        Usage.increment(workspace_id, %{quota_rejections: 1})
        {:error, quota_error}

      {:error, :rate_limited} ->
        Usage.increment(workspace_id, %{rate_limited: 1})
        {:error, :rate_limited}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists execution jobs for a sprite.
  """
  @spec list_jobs(Scope.t() | nil, String.t(), String.t()) ::
          {:ok, [ExecJob.t()]} | {:error, error_reason()}
  def list_jobs(scope, workspace_id, sprite_id) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_read(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id) do
      jobs =
        from(job in ExecJob,
          where: job.workspace_id == ^workspace_id and job.sprite_id == ^sprite.id,
          order_by: [desc: job.inserted_at]
        )
        |> Repo.all()

      {:ok, jobs}
    end
  end

  @doc """
  Gets one job.
  """
  @spec get_job(Scope.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, ExecJob.t()} | {:error, error_reason()}
  def get_job(scope, workspace_id, sprite_id, job_id) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_read(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id),
         {:ok, job} <- fetch_job(workspace_id, sprite.id, job_id) do
      {:ok, job}
    end
  end

  @doc """
  Lists persisted job log chunks after a sequence cursor.
  """
  @spec list_job_logs(
          Scope.t() | nil,
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          pos_integer()
        ) ::
          {:ok, [ExecLogChunk.t()]} | {:error, error_reason()}
  def list_job_logs(scope, workspace_id, sprite_id, job_id, after_seq, limit)
      when is_integer(after_seq) and is_integer(limit) and limit > 0 do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_read(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id),
         {:ok, job} <- fetch_job(workspace_id, sprite.id, job_id) do
      chunks =
        from(chunk in ExecLogChunk,
          where: chunk.job_id == ^job.id and chunk.seq > ^after_seq,
          order_by: [asc: chunk.seq],
          limit: ^min(limit, 1_000)
        )
        |> Repo.all()

      {:ok, chunks}
    end
  end

  def list_job_logs(_scope, _workspace_id, _sprite_id, _job_id, _after_seq, _limit),
    do: {:error, :job_not_found}

  @doc """
  Cancels a queued/running job.
  """
  @spec cancel_job(Scope.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, ExecJob.t()} | {:error, error_reason()}
  def cancel_job(scope, workspace_id, sprite_id, job_id) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_execute(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id),
         {:ok, job} <- fetch_job(workspace_id, sprite.id, job_id) do
      now = DateTime.utc_now()

      cond do
        job.state == :queued ->
          maybe_cancel_oban_job(job.oban_job_id)

          job
          |> ExecJob.changeset(%{state: :canceled, cancel_requested_at: now, finished_at: now})
          |> Repo.update()

        job.state == :running and is_binary(job.remote_session_id) ->
          _ = Http.kill_exec_session(sprite.remote_name, job.remote_session_id)

          job
          |> ExecJob.changeset(%{state: :canceled, cancel_requested_at: now, finished_at: now})
          |> Repo.update()

        job.state in [:succeeded, :failed, :timed_out, :canceled, :system_error] ->
          {:ok, job}

        true ->
          job
          |> ExecJob.changeset(%{cancel_requested_at: now, state: :canceled, finished_at: now})
          |> Repo.update()
      end
    end
  end

  @doc """
  Opens a console lease.
  """
  @spec open_console(Scope.t() | nil, String.t(), String.t(), map()) ::
          {:ok, ConsoleSession.t()} | {:error, error_reason()}
  def open_console(scope, workspace_id, sprite_id, opts \\ %{}) do
    opts = normalize_attrs(opts)

    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_execute(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id),
         :ok <- Quota.check(workspace_id, :console_sessions),
         {:ok, console_session} <-
           %ConsoleSession{}
           |> ConsoleSession.changeset(%{
             sprite_id: sprite.id,
             workspace_id: workspace_id,
             opened_by_user_id: workspace_scope.user.id,
             state: :active,
             opened_at: DateTime.utc_now(),
             rows: normalize_integer(attr(opts, :rows), 24),
             cols: normalize_integer(attr(opts, :cols), 80)
           })
           |> Repo.insert() do
      {:ok, console_session}
    end
  end

  @doc """
  Closes a console lease.
  """
  @spec close_console(Scope.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, ConsoleSession.t()} | {:error, error_reason()}
  def close_console(scope, workspace_id, sprite_id, console_id) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_execute(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id),
         {:ok, console_session} <- fetch_console_session(workspace_id, sprite.id, console_id),
         {:ok, closed_session} <-
           console_session
           |> ConsoleSession.changeset(%{
             state: :closed,
             closed_at: DateTime.utc_now(),
             close_reason: "closed"
           })
           |> Repo.update() do
      Usage.increment(workspace_id, %{console_seconds: console_duration_seconds(console_session)})
      emit_event([:fizz, :sprites, :console, :closed], %{count: 1}, %{workspace_id: workspace_id})
      FizzWeb.Endpoint.broadcast("sprite_console:#{console_id}", "closed", %{reason: "closed"})
      {:ok, closed_session}
    end
  end

  @doc """
  Gets a console session by topic id for channel auth.
  """
  @spec get_console_session(Scope.t() | nil, String.t()) ::
          {:ok, ConsoleSession.t()} | {:error, error_reason()}
  def get_console_session(scope, console_id) when is_binary(console_id) do
    session =
      from(console_session in ConsoleSession,
        where: console_session.id == ^console_id,
        preload: [:sprite]
      )
      |> Repo.one()

    with %ConsoleSession{} = console_session <- session,
         {:ok, workspace_scope} <- resolve_workspace_scope(scope, console_session.workspace_id),
         :ok <- authorize_execute(workspace_scope) do
      {:ok, console_session}
    else
      nil -> {:error, :console_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Marks a console as errored.
  """
  @spec mark_console_errored(String.t(), String.t()) :: :ok
  def mark_console_errored(console_id, reason) do
    if console_id do
      from(console_session in ConsoleSession, where: console_session.id == ^console_id)
      |> Repo.update_all(
        set: [
          state: :errored,
          closed_at: DateTime.utc_now(),
          close_reason: String.slice(to_string(reason), 0, 280)
        ]
      )
    end

    :ok
  end

  @doc """
  Updates console remote session id.
  """
  @spec update_console_remote_session_id(String.t(), String.t()) :: :ok
  def update_console_remote_session_id(console_id, remote_session_id) do
    from(console_session in ConsoleSession, where: console_session.id == ^console_id)
    |> Repo.update_all(set: [remote_session_id: remote_session_id])

    :ok
  end

  @doc """
  Lists services for a sprite.
  """
  @spec list_services(Scope.t() | nil, String.t(), String.t()) ::
          {:ok, [Service.t()]} | {:error, error_reason()}
  def list_services(scope, workspace_id, sprite_id) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_read(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id) do
      services =
        from(service in Service,
          where: service.workspace_id == ^workspace_id and service.sprite_id == ^sprite.id,
          order_by: [asc: service.name]
        )
        |> Repo.all()

      {:ok, services}
    end
  end

  @doc """
  Returns one service by name.
  """
  @spec get_service(Scope.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, Service.t()} | {:error, error_reason()}
  def get_service(scope, workspace_id, sprite_id, service_name) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_read(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id) do
      case Repo.get_by(Service,
             workspace_id: workspace_id,
             sprite_id: sprite.id,
             name: service_name
           ) do
        %Service{} = service -> {:ok, service}
        nil -> {:error, :service_not_found}
      end
    end
  end

  @doc """
  Creates or updates service definition (private by default).
  """
  @spec upsert_service(Scope.t() | nil, String.t(), String.t(), String.t(), map()) ::
          {:ok, Service.t()} | {:error, error_reason()}
  def upsert_service(scope, workspace_id, sprite_id, service_name, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_manage(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id),
         :ok <- Quota.check(workspace_id, :services_per_sprite, sprite_id: sprite.id),
         {:ok, _response} <-
           Http.put_service(sprite.remote_name, service_name, %{
             cmd: attr(attrs, :cmd),
             args: normalize_string_list(attr(attrs, :args)),
             needs: normalize_string_list(attr(attrs, :needs))
           }),
         {:ok, service} <- upsert_local_service(workspace_id, sprite, service_name, attrs) do
      {:ok, service}
    end
  end

  @doc """
  Starts a named service.
  """
  @spec start_service(Scope.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, Service.t()} | {:error, error_reason()}
  def start_service(scope, workspace_id, sprite_id, service_name) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_execute(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id),
         {:ok, _response} <- Http.start_service(sprite.remote_name, service_name),
         {:ok, service} <-
           update_local_service_status(workspace_id, sprite.id, service_name, :running) do
      {:ok, service}
    end
  end

  @doc """
  Stops a named service.
  """
  @spec stop_service(Scope.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, Service.t()} | {:error, error_reason()}
  def stop_service(scope, workspace_id, sprite_id, service_name) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_execute(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id),
         {:ok, _response} <- Http.stop_service(sprite.remote_name, service_name),
         {:ok, service} <-
           update_local_service_status(workspace_id, sprite.id, service_name, :stopped) do
      {:ok, service}
    end
  end

  @doc """
  Fetches short-lived service logs.
  """
  @spec service_logs(Scope.t() | nil, String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map() | list()} | {:error, error_reason()}
  def service_logs(scope, workspace_id, sprite_id, service_name, opts \\ []) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_read(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id),
         {:ok, response} <- Http.service_logs(sprite.remote_name, service_name, opts) do
      {:ok, response}
    end
  end

  @doc """
  Lists checkpoints from remote API and keeps a local cache.
  """
  @spec list_checkpoints(Scope.t() | nil, String.t(), String.t()) ::
          {:ok, [map()]} | {:error, error_reason()}
  def list_checkpoints(scope, workspace_id, sprite_id) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_read(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id),
         {:ok, remote_sprite} <- Client.sprite(sprite.remote_name),
         {:ok, checkpoints} <- Sprites.list_checkpoints(remote_sprite) do
      Enum.each(checkpoints, fn checkpoint ->
        upsert_local_checkpoint(workspace_id, sprite.id, workspace_scope.user.id, checkpoint)
      end)

      {:ok, Enum.map(checkpoints, &checkpoint_to_map/1)}
    end
  end

  @doc """
  Creates a checkpoint and returns the latest checkpoint metadata.
  """
  @spec create_checkpoint(Scope.t() | nil, String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, error_reason()}
  def create_checkpoint(scope, workspace_id, sprite_id, attrs \\ %{}) do
    attrs = normalize_attrs(attrs)

    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_execute(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id),
         {:ok, remote_sprite} <- Client.sprite(sprite.remote_name),
         {:ok, checkpoints_before} <- Sprites.list_checkpoints(remote_sprite),
         :ok <-
           Quota.check(
             workspace_id,
             :checkpoints_per_sprite,
             current_count: length(checkpoints_before)
           ),
         {:ok, _messages} <-
           Sprites.create_checkpoint(remote_sprite, comment: attr(attrs, :comment) || ""),
         {:ok, checkpoints_after} <- Sprites.list_checkpoints(remote_sprite),
         %{} = newest_checkpoint <- newest_checkpoint(checkpoints_after) do
      upsert_local_checkpoint(
        workspace_id,
        sprite.id,
        workspace_scope.user.id,
        newest_checkpoint
      )

      {:ok, checkpoint_to_map(newest_checkpoint)}
    else
      nil -> {:error, :checkpoint_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Restores a sprite from a checkpoint.
  """
  @spec restore_checkpoint(Scope.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, error_reason()}
  def restore_checkpoint(scope, workspace_id, sprite_id, checkpoint_id) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_execute(workspace_scope),
         {:ok, sprite} <- fetch_sprite(workspace_id, sprite_id),
         {:ok, remote_sprite} <- Client.sprite(sprite.remote_name),
         {:ok, messages} <- Sprites.restore_checkpoint(remote_sprite, checkpoint_id) do
      {:ok, Enum.map(messages, &stream_message_to_map/1)}
    end
  end

  @doc """
  Returns workspace limits.
  """
  @spec get_limits(Scope.t() | nil, String.t()) ::
          {:ok, WorkspaceSpriteLimit.t() | nil} | {:error, error_reason()}
  def get_limits(scope, workspace_id) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_read(workspace_scope) do
      {:ok, Quota.ensure_limits(workspace_id)}
    end
  end

  @doc """
  Updates workspace limits.
  """
  @spec update_limits(Scope.t() | nil, String.t(), map()) ::
          {:ok, WorkspaceSpriteLimit.t()} | {:error, error_reason() | Ecto.Changeset.t()}
  def update_limits(scope, workspace_id, attrs) when is_map(attrs) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_manage(workspace_scope),
         {:ok, limits} <- Quota.update_limits(workspace_id, normalize_attrs(attrs)) do
      {:ok, limits}
    end
  end

  @doc """
  Returns daily usage series.
  """
  @spec get_usage(Scope.t() | nil, String.t(), keyword()) ::
          {:ok, list()} | {:error, error_reason()}
  def get_usage(scope, workspace_id, opts \\ []) do
    with {:ok, workspace_scope} <- resolve_workspace_scope(scope, workspace_id),
         :ok <- authorize_read(workspace_scope) do
      {:ok, Usage.get(workspace_id, opts)}
    end
  end

  @doc """
  Authorizes channel access for a job log topic and returns the job.
  """
  @spec authorize_job_topic(Scope.t() | nil, String.t()) ::
          {:ok, ExecJob.t()} | {:error, error_reason()}
  def authorize_job_topic(scope, job_id) when is_binary(job_id) do
    job =
      from(exec_job in ExecJob,
        where: exec_job.id == ^job_id,
        preload: [:sprite]
      )
      |> Repo.one()

    with %ExecJob{} = exec_job <- job,
         {:ok, workspace_scope} <- resolve_workspace_scope(scope, exec_job.workspace_id),
         :ok <- authorize_read(workspace_scope) do
      {:ok, exec_job}
    else
      nil -> {:error, :job_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Persists one output chunk and broadcasts it on the job topic.
  """
  @spec append_job_chunk(String.t(), atom(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def append_job_chunk(exec_job_id, stream, seq, chunk)
      when is_binary(exec_job_id) and is_integer(seq) and is_binary(chunk) do
    byte_size = byte_size(chunk)

    case %ExecLogChunk{}
         |> ExecLogChunk.changeset(%{
           job_id: exec_job_id,
           seq: seq,
           stream: stream,
           chunk: chunk,
           byte_size: byte_size
         })
         |> Repo.insert() do
      {:ok, log_chunk} ->
        payload = %{
          seq: log_chunk.seq,
          stream: to_string(log_chunk.stream),
          chunk: Base.encode64(log_chunk.chunk),
          byte_size: log_chunk.byte_size
        }

        FizzWeb.Endpoint.broadcast("sprite_logs:#{exec_job_id}", "chunk", payload)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Updates execution job state and emits a channel event.
  """
  @spec transition_job(String.t(), atom(), map()) :: {:ok, ExecJob.t()} | {:error, term()}
  def transition_job(exec_job_id, state, attrs \\ %{})
      when is_binary(exec_job_id) and is_map(attrs) do
    with %ExecJob{} = exec_job <- Repo.get(ExecJob, exec_job_id),
         {:ok, updated_job} <-
           exec_job
           |> ExecJob.changeset(Map.put(attrs, :state, state))
           |> Repo.update() do
      FizzWeb.Endpoint.broadcast("sprite_logs:#{exec_job_id}", "job_state", %{
        state: to_string(state)
      })

      emit_event([:fizz, :sprites, :job, :state], %{count: 1}, %{state: state})
      {:ok, updated_job}
    else
      nil -> {:error, :job_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Cleanup routine for old log chunks/checkpoints/rate windows/usage rows.
  """
  @spec gc() :: :ok
  def gc do
    log_cutoff =
      DateTime.utc_now() |> DateTime.add(-Client.log_retention_days() * 86_400, :second)

    from(chunk in ExecLogChunk, where: chunk.inserted_at < ^log_cutoff)
    |> Repo.delete_all()

    checkpoint_cutoff =
      DateTime.utc_now() |> DateTime.add(-Client.checkpoint_retention_days() * 86_400, :second)

    from(checkpoint in Checkpoint, where: checkpoint.inserted_at < ^checkpoint_cutoff)
    |> Repo.delete_all()

    _ = Usage.prune_older_than(Client.log_retention_days() * 4)
    _ = RateLimiter.prune_older_than(Client.log_retention_days())

    :ok
  end

  @doc """
  Marks running jobs with stale heartbeat as system_error.
  """
  @spec reconcile_stale_jobs(pos_integer()) :: non_neg_integer()
  def reconcile_stale_jobs(stale_seconds \\ 120) do
    threshold = DateTime.utc_now() |> DateTime.add(-stale_seconds, :second)

    {count, _} =
      from(exec_job in ExecJob,
        where:
          exec_job.state == :running and
            (is_nil(exec_job.heartbeat_at) or exec_job.heartbeat_at < ^threshold)
      )
      |> Repo.update_all(
        set: [
          state: :system_error,
          error_code: "stale_job",
          error_message: "Marked stale by reconcile worker",
          finished_at: DateTime.utc_now()
        ]
      )

    count
  end

  @doc """
  Reaps old active consoles as a safety net.
  """
  @spec reap_old_consoles(pos_integer()) :: non_neg_integer()
  def reap_old_consoles(idle_seconds \\ 300) do
    threshold = DateTime.utc_now() |> DateTime.add(-idle_seconds, :second)

    {count, _} =
      from(console_session in ConsoleSession,
        where:
          console_session.state == :active and
            console_session.inserted_at < ^threshold
      )
      |> Repo.update_all(
        set: [state: :closed, closed_at: DateTime.utc_now(), close_reason: "reaped"]
      )

    count
  end

  defp fetch_workspace_limits(workspace_id) do
    case Quota.ensure_limits(workspace_id) do
      %WorkspaceSpriteLimit{} = workspace_limit -> {:ok, workspace_limit}
      _ -> {:error, :workspace_not_found}
    end
  end

  defp insert_local_sprite(workspace_scope, workspace_id, attrs, remote_name, remote_sprite) do
    %Sprite{}
    |> Sprite.changeset(%{
      workspace_id: workspace_id,
      created_by_user_id: workspace_scope.user.id,
      name: attr(attrs, :name),
      remote_name: remote_name,
      remote_id: Map.get(remote_sprite, :id),
      status: :ready,
      url: Map.get(remote_sprite, :url),
      url_auth_mode: normalize_url_auth_mode(attr(attrs, :url_auth_mode)),
      config: attr(attrs, :config) || %{},
      metadata: attr(attrs, :metadata) || %{},
      last_seen_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  defp upsert_local_service(workspace_id, sprite, service_name, attrs) do
    service =
      Repo.get_by(Service, workspace_id: workspace_id, sprite_id: sprite.id, name: service_name) ||
        %Service{workspace_id: workspace_id, sprite_id: sprite.id, name: service_name}

    service
    |> Service.changeset(%{
      workspace_id: workspace_id,
      sprite_id: sprite.id,
      name: service_name,
      cmd: attr(attrs, :cmd),
      args: normalize_string_list(attr(attrs, :args)),
      needs: normalize_string_list(attr(attrs, :needs)),
      published: attr(attrs, :published) in [true, "true", 1, "1"],
      metadata: attr(attrs, :metadata) || %{}
    })
    |> Repo.insert_or_update()
  end

  defp update_local_service_status(workspace_id, sprite_id, service_name, status) do
    case Repo.get_by(Service,
           workspace_id: workspace_id,
           sprite_id: sprite_id,
           name: service_name
         ) do
      %Service{} = service ->
        now = DateTime.utc_now()

        attrs =
          if status == :running do
            %{status: :running, last_started_at: now}
          else
            %{status: :stopped, last_stopped_at: now}
          end

        service
        |> Service.changeset(attrs)
        |> Repo.update()

      nil ->
        {:error, :service_not_found}
    end
  end

  defp upsert_local_checkpoint(workspace_id, sprite_id, user_id, checkpoint) do
    remote_checkpoint_id = checkpoint_id(checkpoint)

    if is_binary(remote_checkpoint_id) and byte_size(remote_checkpoint_id) > 0 do
      attrs = %{
        workspace_id: workspace_id,
        sprite_id: sprite_id,
        created_by_user_id: user_id,
        remote_checkpoint_id: remote_checkpoint_id,
        comment: checkpoint_comment(checkpoint),
        created_at_remote: checkpoint_created_at(checkpoint)
      }

      checkpoint_record =
        Repo.get_by(Checkpoint,
          workspace_id: workspace_id,
          sprite_id: sprite_id,
          remote_checkpoint_id: remote_checkpoint_id
        ) || %Checkpoint{}

      checkpoint_record
      |> Checkpoint.changeset(attrs)
      |> Repo.insert_or_update()
    else
      :ok
    end
  end

  defp resolve_workspace_scope(%Scope{} = scope, workspace_id) when is_binary(workspace_id) do
    Accounts.build_scope_for_workspace(scope, workspace_id)
  end

  defp resolve_workspace_scope(_scope, _workspace_id), do: {:error, :unauthenticated}

  defp authorize_read(%Scope{} = workspace_scope) do
    cond do
      Scope.organization_member?(workspace_scope) -> :ok
      workspace_scope.workspace_role in [:admin, :member, :viewer] -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp authorize_manage(%Scope{} = workspace_scope) do
    if Scope.organization_admin?(workspace_scope) or Scope.workspace_admin?(workspace_scope) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp authorize_execute(%Scope{} = workspace_scope) do
    cond do
      Scope.organization_admin?(workspace_scope) -> :ok
      Scope.workspace_admin?(workspace_scope) -> :ok
      workspace_scope.workspace_role == :member -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp fetch_sprite(workspace_id, sprite_id) do
    case Repo.get_by(Sprite, id: sprite_id, workspace_id: workspace_id) do
      %Sprite{} = sprite -> {:ok, sprite}
      nil -> {:error, :sprite_not_found}
    end
  end

  defp fetch_job(workspace_id, sprite_id, job_id) do
    case Repo.get_by(ExecJob, id: job_id, workspace_id: workspace_id, sprite_id: sprite_id) do
      %ExecJob{} = job -> {:ok, job}
      nil -> {:error, :job_not_found}
    end
  end

  defp fetch_console_session(workspace_id, sprite_id, console_id) do
    case Repo.get_by(ConsoleSession,
           id: console_id,
           workspace_id: workspace_id,
           sprite_id: sprite_id
         ) do
      %ConsoleSession{} = console_session -> {:ok, console_session}
      nil -> {:error, :console_not_found}
    end
  end

  defp remote_name_for(workspace_id, name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    suffix = System.unique_integer([:positive])
    workspace_suffix = workspace_id |> String.replace("-", "") |> String.slice(0, 8)

    "fizz-#{workspace_suffix}-#{slug}-#{suffix}"
  end

  defp apply_default_network_policy(remote_sprite, attrs) do
    allowlist = normalize_string_list(attr(attrs, :network_allowlist))

    rules =
      allowlist
      |> Enum.map(fn domain ->
        %Sprites.Policy.Rule{domain: domain, action: "allow"}
      end)
      |> Kernel.++([%Sprites.Policy.Rule{domain: "*", action: "deny"}])

    policy = %Sprites.Policy{rules: rules}

    case Sprites.update_network_policy(remote_sprite, policy) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to apply default network policy: #{inspect(reason)}")
        :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_cancel_oban_job(nil), do: :ok

  defp maybe_cancel_oban_job(oban_job_id) when is_integer(oban_job_id) do
    _ = Oban.cancel_job(oban_job_id)
    :ok
  end

  defp maybe_cancel_oban_job(_oban_job_id), do: :ok

  defp console_duration_seconds(%ConsoleSession{opened_at: nil}), do: 0

  defp console_duration_seconds(%ConsoleSession{opened_at: opened_at}) do
    DateTime.diff(DateTime.utc_now(), opened_at, :second)
  end

  defp normalize_url_auth_mode(mode) when mode in [:default, :public, :bearer], do: mode
  defp normalize_url_auth_mode("default"), do: :default
  defp normalize_url_auth_mode("public"), do: :public
  defp normalize_url_auth_mode("bearer"), do: :bearer
  defp normalize_url_auth_mode(_mode), do: :default

  defp normalize_sprite_status(status)
       when status in [:provisioning, :ready, :error, :deleting, :deleted],
       do: status

  defp normalize_sprite_status("provisioning"), do: :provisioning
  defp normalize_sprite_status("ready"), do: :ready
  defp normalize_sprite_status("error"), do: :error
  defp normalize_sprite_status("deleting"), do: :deleting
  defp normalize_sprite_status("deleted"), do: :deleted
  defp normalize_sprite_status(_status), do: :ready

  defp maybe_update_remote_url_auth(_sprite, nil), do: :ok

  defp maybe_update_remote_url_auth(%Sprite{remote_name: remote_name}, mode) do
    auth =
      case normalize_url_auth_mode(mode) do
        :public -> "none"
        :bearer -> "bearer"
        :default -> "bearer"
      end

    case Http.update_sprite_url_settings(remote_name, %{auth: auth}) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_string_list(nil), do: []

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(value) when is_binary(value), do: [value]
  defp normalize_string_list(_value), do: []

  defp normalize_env_map(nil), do: %{}

  defp normalize_env_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn
      {k, v}, acc when is_binary(k) and is_binary(v) -> Map.put(acc, k, v)
      {k, v}, acc when is_atom(k) and is_binary(v) -> Map.put(acc, Atom.to_string(k), v)
      _pair, acc -> acc
    end)
  end

  defp normalize_env_map(_value), do: %{}

  defp normalize_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        case safe_to_existing_atom(key) do
          {:ok, atom} -> Map.put(acc, atom, value)
          :error -> acc
        end

      _entry, acc ->
        acc
    end)
  end

  defp normalize_attrs(_attrs), do: %{}

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))

  defp normalize_integer(nil, fallback), do: fallback
  defp normalize_integer(value, _fallback) when is_integer(value), do: value

  defp normalize_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> fallback
    end
  end

  defp normalize_integer(_value, fallback), do: fallback

  defp safe_to_existing_atom(key) do
    try do
      {:ok, String.to_existing_atom(key)}
    rescue
      ArgumentError -> :error
    end
  end

  defp checkpoint_to_map(checkpoint) do
    %{
      id: checkpoint_id(checkpoint),
      comment: checkpoint_comment(checkpoint),
      create_time: checkpoint_created_at(checkpoint),
      history: checkpoint_history(checkpoint)
    }
  end

  defp checkpoint_id(%{id: id}) when is_binary(id), do: id
  defp checkpoint_id(%{"id" => id}) when is_binary(id), do: id
  defp checkpoint_id(_checkpoint), do: nil

  defp checkpoint_comment(%{comment: comment}) when is_binary(comment), do: comment
  defp checkpoint_comment(%{"comment" => comment}) when is_binary(comment), do: comment
  defp checkpoint_comment(_checkpoint), do: nil

  defp checkpoint_created_at(%{create_time: %DateTime{} = create_time}), do: create_time

  defp checkpoint_created_at(%{"create_time" => create_time}) when is_binary(create_time),
    do: create_time

  defp checkpoint_created_at(_checkpoint), do: nil

  defp checkpoint_history(%{history: history}) when is_list(history), do: history
  defp checkpoint_history(%{"history" => history}) when is_list(history), do: history
  defp checkpoint_history(_checkpoint), do: []

  defp newest_checkpoint(checkpoints) when is_list(checkpoints) do
    checkpoints
    |> Enum.sort_by(&checkpoint_created_sort_key/1, {:desc, DateTime})
    |> List.first()
  end

  defp newest_checkpoint(_checkpoints), do: nil

  defp checkpoint_created_sort_key(checkpoint) do
    case checkpoint_created_at(checkpoint) do
      %DateTime{} = create_time -> create_time
      _ -> ~U[1970-01-01 00:00:00Z]
    end
  end

  defp stream_message_to_map(message) do
    %{
      type: Map.get(message, :type),
      data: Map.get(message, :data),
      error: Map.get(message, :error)
    }
  end

  defp emit_event(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  rescue
    _ -> :ok
  end
end
