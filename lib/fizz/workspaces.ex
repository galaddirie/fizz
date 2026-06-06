defmodule Fizz.Workspaces do
  @moduledoc """
  Project-scoped broker context for workspace lifecycle, jobs, consoles,
  services, and checkpoints.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Fizz.Accounts
  alias Fizz.Accounts.Scope
  alias Fizz.Repo

  alias Fizz.Workspaces.{
    Checkpoint,
    ConsoleSession,
    ExecJob,
    ExecLogChunk,
    ProviderRegistry,
    Service,
    Workspace
  }

  alias Fizz.Workspaces.Workers.ExecJobWorker

  @type error_reason ::
          :forbidden
          | :project_not_found
          | :workspace_not_found
          | :job_not_found
          | :console_not_found
          | :service_not_found
          | :checkpoint_not_found
          | :unauthenticated
          | :workspace_provider_not_configured
          | {:unknown_workspace_provider, String.t()}
          | term()

  @default_network_allowlist [
    "github.com",
    "api.github.com",
    "*.githubusercontent.com"
  ]

  @doc """
  Returns project-aware scope for the project id.
  """
  @spec resolve_project_scope(Scope.t() | nil, String.t()) ::
          {:ok, Scope.t()} | {:error, error_reason()}
  def resolve_project_scope(scope, project_id),
    do: build_project_scope(scope, project_id)

  @doc """
  Lists workspaces in the project.
  """
  @spec list_project_workspaces(Scope.t() | nil, String.t()) ::
          {:ok, [Workspace.t()]} | {:error, error_reason()}
  def list_project_workspaces(scope, project_id) do
    with {:ok, _project_scope} <- authorize_project(scope, project_id, :read) do
      workspaces =
        from(workspace in Workspace,
          where: workspace.project_id == ^project_id,
          order_by: [asc: workspace.inserted_at]
        )
        |> Repo.all()

      {:ok, workspaces}
    end
  end

  @doc """
  Gets a workspace by id within the project.
  """
  @spec get_workspace(Scope.t() | nil, String.t(), String.t()) ::
          {:ok, Workspace.t()} | {:error, error_reason()}
  def get_workspace(scope, project_id, workspace_id) do
    with {:ok, _project_scope} <- authorize_project(scope, project_id, :read),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id) do
      {:ok, workspace}
    end
  end

  @doc """
  Updates mutable workspace fields and optionally URL auth settings remotely.
  """
  @spec update_workspace(Scope.t() | nil, String.t(), String.t(), map()) ::
          {:ok, Workspace.t()} | {:error, error_reason() | Ecto.Changeset.t()}
  def update_workspace(scope, project_id, workspace_id, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, _project_scope} <- authorize_project(scope, project_id, :manage),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id),
         :ok <- maybe_update_remote_url_auth(workspace, attr(attrs, :url_auth_mode)),
         {:ok, updated_workspace} <-
           workspace
           |> Workspace.changeset(%{
             status: normalize_workspace_status(attr(attrs, :status)),
             url_auth_mode: normalize_url_auth_mode(attr(attrs, :url_auth_mode)),
             metadata: attr(attrs, :metadata) || workspace.metadata,
             config: attr(attrs, :config) || workspace.config
           })
           |> Repo.update() do
      {:ok, updated_workspace}
    end
  end

  @doc """
  Creates a new workspace for the project and applies the default egress policy.
  """
  @spec create_workspace(Scope.t() | nil, String.t(), map()) ::
          {:ok, Workspace.t()} | {:error, error_reason()}
  def create_workspace(scope, project_id, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, project_scope} <- authorize_project(scope, project_id, :manage),
         {:ok, provider} <- ProviderRegistry.provider(),
         name when is_binary(name) <- attr(attrs, :name),
         remote_name <- remote_name_for(project_id, name),
         {:ok, workspace} <-
           insert_local_workspace(project_scope, project_id, attrs, remote_name),
         {:ok, workspace} <-
           provision_remote(provider, workspace, remote_name, attrs) do
      emit_event([:fizz, :workspaces, :workspace, :created], %{count: 1}, %{
        project_id: project_id
      })

      {:ok, workspace}
    else
      nil -> {:error, :invalid_workspace_name}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a workspace remotely and marks it deleted locally.
  """
  @spec delete_workspace(Scope.t() | nil, String.t(), String.t()) ::
          {:ok, Workspace.t()} | {:error, error_reason()}
  def delete_workspace(scope, project_id, workspace_id) do
    with {:ok, _project_scope} <- authorize_project(scope, project_id, :manage),
         {:ok, provider} <- ProviderRegistry.provider(),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id),
         :ok <- provider.delete_workspace(workspace.remote_name),
         {:ok, updated_workspace} <-
           workspace
           |> Workspace.changeset(%{status: :deleted, deleted_at: DateTime.utc_now()})
           |> Repo.update() do
      emit_event([:fizz, :workspaces, :workspace, :deleted], %{count: 1}, %{
        project_id: project_id
      })

      {:ok, updated_workspace}
    end
  end

  @doc """
  Enqueues a non-interactive execution job.
  """
  @spec queue_job(Scope.t() | nil, String.t(), String.t(), map()) ::
          {:ok, ExecJob.t()} | {:error, error_reason()}
  def queue_job(scope, project_id, workspace_id, exec_spec) when is_map(exec_spec) do
    exec_spec = normalize_attrs(exec_spec)

    with {:ok, project_scope} <- authorize_project(scope, project_id, :execute),
         {:ok, provider} <- ProviderRegistry.provider(),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id),
         command when is_binary(command) <- attr(exec_spec, :command),
         args <- normalize_string_list(attr(exec_spec, :args)),
         timeout_ms <- attr(exec_spec, :timeout_ms) || provider.exec_timeout_ms_default(),
         {:ok, %{updated_exec_job: exec_job}} <-
           enqueue_job_multi(
             workspace,
             project_id,
             project_scope.user.id,
             command,
             args,
             normalize_env_map(attr(exec_spec, :env)),
             attr(exec_spec, :dir),
             timeout_ms
           )
           |> Repo.transaction() do
      emit_event([:fizz, :workspaces, :job, :queued], %{count: 1}, %{project_id: project_id})
      {:ok, exec_job}
    else
      nil -> {:error, :invalid_command}
      {:error, _step, reason, _changes} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists execution jobs for a workspace.
  """
  @spec list_workspace_jobs(Scope.t() | nil, String.t(), String.t()) ::
          {:ok, [ExecJob.t()]} | {:error, error_reason()}
  def list_workspace_jobs(scope, project_id, workspace_id) do
    with {:ok, _project_scope} <- authorize_project(scope, project_id, :read),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id) do
      jobs =
        from(job in ExecJob,
          where: job.project_id == ^project_id and job.workspace_id == ^workspace.id,
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
  def get_job(scope, project_id, workspace_id, job_id) do
    with {:ok, _project_scope} <- authorize_project(scope, project_id, :read),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id),
         {:ok, job} <- fetch_job(project_id, workspace.id, job_id) do
      {:ok, job}
    end
  end

  @doc """
  Lists persisted job log chunks after a sequence cursor.
  """
  @spec tail_job_logs(
          Scope.t() | nil,
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          pos_integer()
        ) ::
          {:ok, [ExecLogChunk.t()]} | {:error, error_reason()}
  def tail_job_logs(scope, project_id, workspace_id, job_id, after_seq, limit)
      when is_integer(after_seq) and is_integer(limit) and limit > 0 do
    with {:ok, _project_scope} <- authorize_project(scope, project_id, :read),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id),
         {:ok, job} <- fetch_job(project_id, workspace.id, job_id) do
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

  def tail_job_logs(_scope, _project_id, _workspace_id, _job_id, _after_seq, _limit),
    do: {:error, :job_not_found}

  @doc """
  Cancels a queued or running job.
  """
  @spec cancel_job(Scope.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, ExecJob.t()} | {:error, error_reason()}
  def cancel_job(scope, project_id, workspace_id, job_id) do
    with {:ok, _project_scope} <- authorize_project(scope, project_id, :execute),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id),
         {:ok, job} <- fetch_job(project_id, workspace.id, job_id) do
      now = DateTime.utc_now()

      cond do
        job.state == :queued ->
          maybe_cancel_oban_job(job.oban_job_id)

          job
          |> ExecJob.changeset(%{state: :canceled, cancel_requested_at: now, finished_at: now})
          |> Repo.update()

        job.state == :running and is_binary(job.remote_session_id) ->
          :ok = maybe_kill_remote_session(workspace.remote_name, job.remote_session_id)

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
  def open_console(scope, project_id, workspace_id, opts \\ %{}) do
    opts = normalize_attrs(opts)

    with {:ok, project_scope} <- authorize_project(scope, project_id, :execute),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id),
         {:ok, console_session} <-
           %ConsoleSession{}
           |> ConsoleSession.changeset(%{
             workspace_id: workspace.id,
             project_id: project_id,
             opened_by_user_id: project_scope.user.id,
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
  @spec close_console(Scope.t() | nil, String.t(), String.t(), String.t(), String.t()) ::
          {:ok, ConsoleSession.t()} | {:error, error_reason()}
  def close_console(scope, project_id, workspace_id, console_id, reason \\ "closed") do
    close_reason = normalize_close_reason(reason)

    with {:ok, _project_scope} <- authorize_project(scope, project_id, :execute),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id),
         {:ok, console_session} <- fetch_console_session(project_id, workspace.id, console_id) do
      close_console_session(console_session, project_id, close_reason)
    end
  end

  @doc """
  Gets a console session by topic id for channel auth.
  """
  @spec authorize_console_session(Scope.t() | nil, String.t()) ::
          {:ok, ConsoleSession.t()} | {:error, error_reason()}
  def authorize_console_session(scope, console_id) when is_binary(console_id) do
    session =
      from(console_session in ConsoleSession,
        where: console_session.id == ^console_id,
        preload: [:workspace]
      )
      |> Repo.one()

    with %ConsoleSession{} = console_session <- session,
         {:ok, _project_scope} <-
           authorize_project(scope, console_session.project_id, :execute) do
      {:ok, console_session}
    else
      nil -> {:error, :console_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Marks a console as errored.
  """
  @spec flag_console_error(String.t(), String.t()) :: :ok
  def flag_console_error(console_id, reason) do
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
  @spec attach_console_remote_session(String.t(), String.t()) :: :ok
  def attach_console_remote_session(console_id, remote_session_id) do
    from(console_session in ConsoleSession, where: console_session.id == ^console_id)
    |> Repo.update_all(set: [remote_session_id: remote_session_id])

    :ok
  end

  @doc """
  Lists services for a workspace.
  """
  @spec list_workspace_services(Scope.t() | nil, String.t(), String.t()) ::
          {:ok, [Service.t()]} | {:error, error_reason()}
  def list_workspace_services(scope, project_id, workspace_id) do
    with {:ok, _project_scope} <- authorize_project(scope, project_id, :read),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id) do
      services =
        from(service in Service,
          where: service.project_id == ^project_id and service.workspace_id == ^workspace.id,
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
  def get_service(scope, project_id, workspace_id, service_name) do
    with {:ok, _project_scope} <- authorize_project(scope, project_id, :read),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id) do
      case Repo.get_by(Service,
             project_id: project_id,
             workspace_id: workspace.id,
             name: service_name
           ) do
        %Service{} = service -> {:ok, service}
        nil -> {:error, :service_not_found}
      end
    end
  end

  @doc """
  Creates or updates a service definition.
  """
  @spec upsert_service(Scope.t() | nil, String.t(), String.t(), String.t(), map()) ::
          {:ok, Service.t()} | {:error, error_reason()}
  def upsert_service(scope, project_id, workspace_id, service_name, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, _project_scope} <- authorize_project(scope, project_id, :manage),
         {:ok, provider} <- ProviderRegistry.provider(),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id),
         {:ok, _response} <-
           provider.put_service(workspace.remote_name, service_name, %{
             cmd: attr(attrs, :cmd),
             args: normalize_string_list(attr(attrs, :args)),
             needs: normalize_string_list(attr(attrs, :needs))
           }),
         {:ok, service} <- upsert_local_service(project_id, workspace, service_name, attrs) do
      {:ok, service}
    end
  end

  @doc """
  Starts a named service.
  """
  @spec start_service(Scope.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, Service.t()} | {:error, error_reason()}
  def start_service(scope, project_id, workspace_id, service_name) do
    with {:ok, _project_scope} <- authorize_project(scope, project_id, :execute),
         {:ok, provider} <- ProviderRegistry.provider(),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id),
         {:ok, _response} <- provider.start_service(workspace.remote_name, service_name),
         {:ok, service} <-
           update_local_service_status(project_id, workspace.id, service_name, :running) do
      {:ok, service}
    end
  end

  @doc """
  Stops a named service.
  """
  @spec stop_service(Scope.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, Service.t()} | {:error, error_reason()}
  def stop_service(scope, project_id, workspace_id, service_name) do
    with {:ok, _project_scope} <- authorize_project(scope, project_id, :execute),
         {:ok, provider} <- ProviderRegistry.provider(),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id),
         {:ok, _response} <- provider.stop_service(workspace.remote_name, service_name),
         {:ok, service} <-
           update_local_service_status(project_id, workspace.id, service_name, :stopped) do
      {:ok, service}
    end
  end

  @doc """
  Fetches short-lived service logs.
  """
  @spec tail_service_logs(Scope.t() | nil, String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map() | list()} | {:error, error_reason()}
  def tail_service_logs(scope, project_id, workspace_id, service_name, opts \\ []) do
    with {:ok, _project_scope} <- authorize_project(scope, project_id, :read),
         {:ok, provider} <- ProviderRegistry.provider(),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id),
         {:ok, response} <- provider.service_logs(workspace.remote_name, service_name, opts) do
      {:ok, response}
    end
  end

  @doc """
  Lists checkpoints from the remote API and keeps a local cache.
  """
  @spec list_workspace_checkpoints(Scope.t() | nil, String.t(), String.t()) ::
          {:ok, [map()]} | {:error, error_reason()}
  def list_workspace_checkpoints(scope, project_id, workspace_id) do
    with {:ok, project_scope} <- authorize_project(scope, project_id, :read),
         {:ok, provider} <- ProviderRegistry.provider(),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id),
         {:ok, checkpoints} <- provider.list_checkpoints(workspace.remote_name) do
      Enum.each(checkpoints, fn checkpoint ->
        upsert_local_checkpoint(project_id, workspace.id, project_scope.user.id, checkpoint)
      end)

      {:ok, checkpoints}
    end
  end

  @doc """
  Creates a checkpoint and returns the latest checkpoint metadata.
  """
  @spec create_checkpoint(Scope.t() | nil, String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, error_reason()}
  def create_checkpoint(scope, project_id, workspace_id, attrs \\ %{}) do
    attrs = normalize_attrs(attrs)

    with {:ok, project_scope} <- authorize_project(scope, project_id, :execute),
         {:ok, provider} <- ProviderRegistry.provider(),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id),
         {:ok, _messages} <-
           provider.create_checkpoint(workspace.remote_name, comment: attr(attrs, :comment) || ""),
         {:ok, checkpoints_after} <- provider.list_checkpoints(workspace.remote_name),
         %{} = newest_checkpoint <- newest_checkpoint(checkpoints_after) do
      upsert_local_checkpoint(
        project_id,
        workspace.id,
        project_scope.user.id,
        newest_checkpoint
      )

      {:ok, newest_checkpoint}
    else
      nil -> {:error, :checkpoint_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Restores a workspace from a checkpoint.
  """
  @spec restore_checkpoint(Scope.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, error_reason()}
  def restore_checkpoint(scope, project_id, workspace_id, checkpoint_id) do
    with {:ok, _project_scope} <- authorize_project(scope, project_id, :execute),
         {:ok, provider} <- ProviderRegistry.provider(),
         {:ok, workspace} <- fetch_workspace(project_id, workspace_id),
         {:ok, messages} <- provider.restore_checkpoint(workspace.remote_name, checkpoint_id) do
      {:ok, messages}
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
        preload: [:workspace]
      )
      |> Repo.one()

    with %ExecJob{} = exec_job <- job,
         {:ok, _project_scope} <- authorize_project(scope, exec_job.project_id, :read) do
      {:ok, exec_job}
    else
      nil -> {:error, :job_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Persists one output chunk and broadcasts it on the job topic.
  """
  @spec append_job_output(String.t(), atom(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def append_job_output(exec_job_id, stream, seq, chunk)
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

        FizzWeb.Endpoint.broadcast("workspace_logs:#{exec_job_id}", "chunk", payload)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Updates execution job state and emits a channel event.
  """
  @spec set_job_state(String.t(), atom(), map()) :: {:ok, ExecJob.t()} | {:error, term()}
  def set_job_state(exec_job_id, state, attrs \\ %{})
      when is_binary(exec_job_id) and is_map(attrs) do
    with %ExecJob{} = exec_job <- Repo.get(ExecJob, exec_job_id),
         {:ok, updated_job} <-
           exec_job
           |> ExecJob.changeset(Map.put(attrs, :state, state))
           |> Repo.update() do
      FizzWeb.Endpoint.broadcast("workspace_logs:#{exec_job_id}", "job_state", %{
        state: to_string(state)
      })

      emit_event([:fizz, :workspaces, :job, :state], %{count: 1}, %{state: state})
      {:ok, updated_job}
    else
      nil -> {:error, :job_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Cleanup routine for old log chunks and checkpoints.
  """
  @spec run_gc() :: :ok
  def run_gc do
    case ProviderRegistry.provider() do
      {:ok, provider} ->
        log_cutoff =
          DateTime.utc_now() |> DateTime.add(-provider.log_retention_days() * 86_400, :second)

        from(chunk in ExecLogChunk, where: chunk.inserted_at < ^log_cutoff)
        |> Repo.delete_all()

        checkpoint_cutoff =
          DateTime.utc_now()
          |> DateTime.add(-provider.checkpoint_retention_days() * 86_400, :second)

        from(checkpoint in Checkpoint, where: checkpoint.inserted_at < ^checkpoint_cutoff)
        |> Repo.delete_all()

      {:error, reason} ->
        Logger.warning("workspace GC skipped: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Marks running jobs with stale heartbeat as system_error.
  """
  @spec recover_stale_jobs(pos_integer()) :: non_neg_integer()
  def recover_stale_jobs(stale_seconds \\ 120) do
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
  @spec reap_idle_consoles(pos_integer()) :: non_neg_integer()
  def reap_idle_consoles(idle_seconds \\ 300) do
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

  defp close_console_session(
         %ConsoleSession{state: :active} = console_session,
         project_id,
         reason
       ) do
    with {:ok, closed_session} <-
           console_session
           |> ConsoleSession.changeset(%{
             state: :closed,
             closed_at: DateTime.utc_now(),
             close_reason: reason
           })
           |> Repo.update() do
      emit_event([:fizz, :workspaces, :console, :closed], %{count: 1}, %{project_id: project_id})

      FizzWeb.Endpoint.broadcast("workspace_console:#{console_session.id}", "closed", %{
        reason: reason
      })

      {:ok, closed_session}
    end
  end

  defp close_console_session(%ConsoleSession{} = console_session, _project_id, _reason),
    do: {:ok, console_session}

  defp enqueue_job_multi(
         workspace,
         project_id,
         requested_by_user_id,
         command,
         args,
         env,
         dir,
         timeout_ms
       ) do
    Multi.new()
    |> Multi.insert(
      :exec_job,
      ExecJob.changeset(%ExecJob{}, %{
        workspace_id: workspace.id,
        project_id: project_id,
        requested_by_user_id: requested_by_user_id,
        state: :queued,
        command: command,
        args: args,
        env: env,
        dir: dir,
        tty: false,
        timeout_ms: timeout_ms
      })
    )
    |> Multi.run(:oban_job, fn _repo, %{exec_job: exec_job} ->
      %{"exec_job_id" => exec_job.id}
      |> ExecJobWorker.new(queue: :workspaces)
      |> Oban.insert()
    end)
    |> Multi.update(:updated_exec_job, fn %{exec_job: exec_job, oban_job: oban_job} ->
      ExecJob.changeset(exec_job, %{oban_job_id: oban_job.id})
    end)
  end

  defp insert_local_workspace(project_scope, project_id, attrs, remote_name) do
    %Workspace{}
    |> Workspace.changeset(%{
      project_id: project_id,
      created_by_user_id: project_scope.user.id,
      name: attr(attrs, :name),
      remote_name: remote_name,
      status: :provisioning,
      url_auth_mode: normalize_url_auth_mode(attr(attrs, :url_auth_mode)),
      config: attr(attrs, :config) || %{},
      metadata: attr(attrs, :metadata) || %{},
      last_seen_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  defp upsert_local_service(project_id, workspace, service_name, attrs) do
    now = DateTime.utc_now()

    %Service{}
    |> Service.changeset(%{
      project_id: project_id,
      workspace_id: workspace.id,
      name: service_name,
      cmd: attr(attrs, :cmd),
      args: normalize_string_list(attr(attrs, :args)),
      needs: normalize_string_list(attr(attrs, :needs)),
      published: attr(attrs, :published) in [true, "true", 1, "1"],
      metadata: attr(attrs, :metadata) || %{},
      updated_at: now
    })
    |> Repo.insert(
      on_conflict:
        {:replace, [:project_id, :cmd, :args, :needs, :published, :metadata, :updated_at]},
      conflict_target: [:workspace_id, :name],
      returning: true
    )
  end

  defp update_local_service_status(project_id, workspace_id, service_name, status) do
    case Repo.get_by(Service,
           project_id: project_id,
           workspace_id: workspace_id,
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

  defp upsert_local_checkpoint(project_id, workspace_id, user_id, checkpoint) do
    remote_checkpoint_id = checkpoint_id(checkpoint)

    if is_binary(remote_checkpoint_id) and byte_size(remote_checkpoint_id) > 0 do
      now = DateTime.utc_now()

      attrs = %{
        project_id: project_id,
        workspace_id: workspace_id,
        created_by_user_id: user_id,
        remote_checkpoint_id: remote_checkpoint_id,
        comment: checkpoint_comment(checkpoint),
        created_at_remote: checkpoint_created_at(checkpoint),
        updated_at: now
      }

      %Checkpoint{}
      |> Checkpoint.changeset(attrs)
      |> Repo.insert(
        on_conflict:
          {:replace,
           [:project_id, :created_by_user_id, :comment, :created_at_remote, :updated_at]},
        conflict_target: [:workspace_id, :remote_checkpoint_id],
        returning: true
      )
    else
      :ok
    end
  end

  defp build_project_scope(%Scope{} = scope, project_id) when is_binary(project_id) do
    Accounts.build_scope_for_project(scope, project_id)
  end

  defp build_project_scope(_scope, _project_id), do: {:error, :unauthenticated}

  defp authorize_project(scope, project_id, permission) do
    with {:ok, project_scope} <- resolve_project_scope(scope, project_id),
         :ok <- authorize_scope(project_scope, permission) do
      {:ok, project_scope}
    end
  end

  defp authorize_scope(project_scope, :read), do: authorize_read(project_scope)
  defp authorize_scope(project_scope, :manage), do: authorize_manage(project_scope)
  defp authorize_scope(project_scope, :execute), do: authorize_execute(project_scope)

  defp authorize_read(%Scope{} = project_scope) do
    cond do
      Scope.organization_member?(project_scope) -> :ok
      project_scope.project_role in [:admin, :member, :viewer] -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp authorize_manage(%Scope{} = project_scope) do
    if Scope.organization_admin?(project_scope) or Scope.project_admin?(project_scope) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp authorize_execute(%Scope{} = project_scope) do
    cond do
      Scope.organization_admin?(project_scope) -> :ok
      Scope.project_admin?(project_scope) -> :ok
      project_scope.project_role == :member -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp fetch_workspace(project_id, workspace_id) do
    case Repo.get_by(Workspace, id: workspace_id, project_id: project_id) do
      %Workspace{} = workspace -> {:ok, workspace}
      nil -> {:error, :workspace_not_found}
    end
  end

  defp fetch_job(project_id, workspace_id, job_id) do
    case Repo.get_by(ExecJob, id: job_id, project_id: project_id, workspace_id: workspace_id) do
      %ExecJob{} = job -> {:ok, job}
      nil -> {:error, :job_not_found}
    end
  end

  defp fetch_console_session(project_id, workspace_id, console_id) do
    case Repo.get_by(ConsoleSession,
           id: console_id,
           project_id: project_id,
           workspace_id: workspace_id
         ) do
      %ConsoleSession{} = console_session -> {:ok, console_session}
      nil -> {:error, :console_not_found}
    end
  end

  defp provision_remote(provider, workspace, remote_name, attrs) do
    allowlist = default_network_allowlist(attrs)

    with {:ok, remote_workspace} <- provider.create_workspace(remote_name, attrs),
         :ok <- provider.apply_network_policy(remote_name, allowlist),
         {:ok, updated_workspace} <-
           workspace
           |> Workspace.changeset(%{
             remote_id: Map.get(remote_workspace, :id),
             status: :ready,
             url: Map.get(remote_workspace, :url)
           })
           |> Repo.update() do
      {:ok, updated_workspace}
    else
      {:error, reason} ->
        Logger.warning("Remote provisioning failed for #{remote_name}, rolling back local record")
        Repo.delete(workspace)
        {:error, reason}
    end
  end

  defp default_network_allowlist(attrs) do
    user_allowlist = normalize_string_list(attr(attrs, :network_allowlist))
    Enum.uniq(@default_network_allowlist ++ user_allowlist)
  end

  defp remote_name_for(project_id, name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    suffix = System.unique_integer([:positive])
    project_suffix = project_id |> String.replace("-", "") |> String.slice(0, 8)

    "fizz-#{project_suffix}-#{slug}-#{suffix}"
  end

  defp maybe_kill_remote_session(remote_name, remote_session_id) do
    case ProviderRegistry.provider() do
      {:ok, provider} ->
        _ = provider.kill_exec_session(remote_name, remote_session_id)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp maybe_cancel_oban_job(nil), do: :ok

  defp maybe_cancel_oban_job(oban_job_id) when is_integer(oban_job_id) do
    _ = Oban.cancel_job(oban_job_id)
    :ok
  end

  defp maybe_cancel_oban_job(_oban_job_id), do: :ok

  defp normalize_url_auth_mode(mode) when mode in [:default, :public, :bearer], do: mode
  defp normalize_url_auth_mode("default"), do: :default
  defp normalize_url_auth_mode("public"), do: :public
  defp normalize_url_auth_mode("bearer"), do: :bearer
  defp normalize_url_auth_mode(_mode), do: :default

  defp normalize_workspace_status(status)
       when status in [:provisioning, :ready, :error, :deleting, :deleted],
       do: status

  defp normalize_workspace_status("provisioning"), do: :provisioning
  defp normalize_workspace_status("ready"), do: :ready
  defp normalize_workspace_status("error"), do: :error
  defp normalize_workspace_status("deleting"), do: :deleting
  defp normalize_workspace_status("deleted"), do: :deleted
  defp normalize_workspace_status(_status), do: :ready

  defp maybe_update_remote_url_auth(_workspace, nil), do: :ok

  defp maybe_update_remote_url_auth(%Workspace{remote_name: remote_name}, mode) do
    with {:ok, provider} <- ProviderRegistry.provider() do
      provider.update_url_auth(remote_name, normalize_url_auth_mode(mode))
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

  defp normalize_close_reason(reason) when is_binary(reason),
    do: reason |> String.trim() |> String.slice(0, 280)

  defp normalize_close_reason(reason),
    do: reason |> to_string() |> String.slice(0, 280)

  defp safe_to_existing_atom(key) do
    try do
      {:ok, String.to_existing_atom(key)}
    rescue
      ArgumentError -> :error
    end
  end

  defp checkpoint_id(%{id: id}) when is_binary(id), do: id
  defp checkpoint_id(%{"id" => id}) when is_binary(id), do: id
  defp checkpoint_id(_checkpoint), do: nil

  defp checkpoint_comment(%{comment: comment}) when is_binary(comment), do: comment
  defp checkpoint_comment(%{"comment" => comment}) when is_binary(comment), do: comment
  defp checkpoint_comment(_checkpoint), do: nil

  defp checkpoint_created_at(%{create_time: %DateTime{} = create_time}), do: create_time

  defp checkpoint_created_at(%{"create_time" => %DateTime{} = create_time}), do: create_time

  defp checkpoint_created_at(%{"create_time" => create_time}) when is_binary(create_time),
    do: create_time

  defp checkpoint_created_at(_checkpoint), do: nil

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

  defp emit_event(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  rescue
    _ -> :ok
  end
end
