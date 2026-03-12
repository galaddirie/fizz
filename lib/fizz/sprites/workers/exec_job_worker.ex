defmodule Fizz.Sprites.Workers.ExecJobWorker do
  @moduledoc """
  Executes queued sprite jobs and persists streamed logs.
  """

  use Oban.Worker,
    queue: :sprites,
    max_attempts: 5,
    unique: [fields: [:args], keys: [:exec_job_id], period: 120]

  import Ecto.Query

  alias Fizz.Accounts
  alias Fizz.Accounts.Scope
  alias Fizz.Integrations
  alias Fizz.Repo
  alias Fizz.Sprites, as: Broker
  alias Fizz.Sprites.{Client, ExecJob, GitCredentialSetup}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"exec_job_id" => exec_job_id}}) do
    case Repo.get(ExecJob, exec_job_id) |> Repo.preload([:sprite, :requested_by_user]) do
      nil ->
        :discard

      %ExecJob{state: state}
      when state in [:succeeded, :failed, :timed_out, :canceled, :system_error] ->
        :ok

      %ExecJob{} = exec_job ->
        run(exec_job)
    end
  end

  defp run(%ExecJob{} = exec_job) do
    now = DateTime.utc_now()

    {:ok, _running_job} =
      Broker.set_job_state(exec_job.id, :running, %{started_at: now, heartbeat_at: now})

    git_env = setup_git_credentials(exec_job)

    with {:ok, remote_sprite} <- Client.sprite(exec_job.sprite.remote_name),
         {:ok, command} <-
           Sprites.spawn(
             remote_sprite,
             exec_job.command,
             exec_job.args,
             owner: self(),
             env: env_tuples(exec_job.env) ++ git_env,
             dir: exec_job.dir
           ) do
      start_ms = System.monotonic_time(:millisecond)
      timeout_ms = exec_job.timeout_ms || Client.exec_timeout_ms_default()

      case collect_output(command, exec_job.id, start_ms, timeout_ms, 0, 0, 0, 0) do
        {:ok, result} ->
          finish_with_exit(exec_job, result)
          :ok

        {:timeout, result} ->
          finish_timed_out(exec_job, result)
          :ok

        {:error, :closed, result} ->
          # Connection closed after output received — treat as success (exit 0)
          # This typically happens when the remote sprite closes TCP before the
          # WebSocket close frame is processed by gun.
          finish_with_exit(exec_job, Map.put(result, :exit_code, 0))
          :ok

        {:error, reason, result} ->
          finish_system_error(exec_job, reason, result)
          {:error, inspect(reason)}
      end
    else
      {:error, reason} ->
        finish_system_error(exec_job, reason, %{
          stdout: 0,
          stderr: 0,
          total: 0,
          seq: 0,
          duration_s: 0
        })

        {:error, inspect(reason)}
    end
  end

  defp collect_output(
         command,
         exec_job_id,
         start_ms,
         timeout_ms,
         seq,
         stdout_bytes,
         stderr_bytes,
         total_bytes
       ) do
    elapsed = System.monotonic_time(:millisecond) - start_ms
    remaining = timeout_ms - elapsed

    if remaining <= 0 do
      stop_command(command)

      {:timeout,
       %{
         exit_code: nil,
         seq: seq,
         stdout: stdout_bytes,
         stderr: stderr_bytes,
         total: total_bytes,
         duration_s: div(max(elapsed, 0), 1_000)
       }}
    else
      receive do
        {:stdout, %{ref: ref}, data} when ref == command.ref ->
          next_seq = seq + 1
          _ = Broker.append_job_output(exec_job_id, :stdout, next_seq, data)

          collect_output(
            command,
            exec_job_id,
            start_ms,
            timeout_ms,
            next_seq,
            stdout_bytes + byte_size(data),
            stderr_bytes,
            total_bytes + byte_size(data)
          )

        {:stderr, %{ref: ref}, data} when ref == command.ref ->
          next_seq = seq + 1
          _ = Broker.append_job_output(exec_job_id, :stderr, next_seq, data)

          collect_output(
            command,
            exec_job_id,
            start_ms,
            timeout_ms,
            next_seq,
            stdout_bytes,
            stderr_bytes + byte_size(data),
            total_bytes + byte_size(data)
          )

        {:exit, %{ref: ref}, exit_code} when ref == command.ref ->
          elapsed_done = System.monotonic_time(:millisecond) - start_ms

          {:ok,
           %{
             exit_code: exit_code,
             seq: seq,
             stdout: stdout_bytes,
             stderr: stderr_bytes,
             total: total_bytes,
             duration_s: div(max(elapsed_done, 0), 1_000)
           }}

        {:error, %{ref: ref}, reason} when ref == command.ref ->
          elapsed_done = System.monotonic_time(:millisecond) - start_ms

          {:error, reason,
           %{
             exit_code: nil,
             seq: seq,
             stdout: stdout_bytes,
             stderr: stderr_bytes,
             total: total_bytes,
             duration_s: div(max(elapsed_done, 0), 1_000)
           }}
      after
        min(remaining, 1_000) ->
          touch_heartbeat(exec_job_id)

          collect_output(
            command,
            exec_job_id,
            start_ms,
            timeout_ms,
            seq,
            stdout_bytes,
            stderr_bytes,
            total_bytes
          )
      end
    end
  end

  defp finish_with_exit(exec_job, result) do
    state = if result.exit_code == 0, do: :succeeded, else: :failed

    _ =
      Broker.set_job_state(exec_job.id, state, %{
        exit_code: result.exit_code,
        finished_at: DateTime.utc_now(),
        bytes_stdout: result.stdout,
        bytes_stderr: result.stderr,
        bytes_total: result.total,
        heartbeat_at: DateTime.utc_now()
      })
  end

  defp finish_timed_out(exec_job, result) do
    _ =
      Broker.set_job_state(exec_job.id, :timed_out, %{
        finished_at: DateTime.utc_now(),
        bytes_stdout: result.stdout,
        bytes_stderr: result.stderr,
        bytes_total: result.total,
        error_code: "timeout",
        error_message: "Execution timed out"
      })
  end

  defp finish_system_error(exec_job, reason, result) do
    _ =
      Broker.set_job_state(exec_job.id, :system_error, %{
        finished_at: DateTime.utc_now(),
        bytes_stdout: result.stdout,
        bytes_stderr: result.stderr,
        bytes_total: result.total,
        error_code: "system_error",
        error_message: inspect(reason)
      })
  end

  defp touch_heartbeat(exec_job_id) do
    from(exec_job in ExecJob, where: exec_job.id == ^exec_job_id)
    |> Repo.update_all(set: [heartbeat_at: DateTime.utc_now()])

    :ok
  end

  defp env_tuples(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp env_tuples(_env), do: []

  defp stop_command(%{pid: pid}) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  rescue
    _ -> :ok
  end

  defp stop_command(_command), do: :ok

  defp setup_git_credentials(%ExecJob{requested_by_user: %Accounts.User{} = user} = exec_job) do
    scope = Scope.for_user(user)

    with {:ok, project_scope} <-
           Accounts.build_scope_for_project(scope, exec_job.project_id),
         {:ok, token_result} <-
           Integrations.fetch_token_for_sprite(
             project_scope,
             exec_job.project_id,
             "github_oauth"
           ) do
      user_opts = git_user_opts(project_scope, exec_job.project_id)

      case GitCredentialSetup.setup(
             exec_job.sprite.remote_name,
             token_result.access_token,
             user_opts
           ) do
        {:ok, env_tuples} ->
          env_tuples

        {:error, reason} ->
          Logger.warning("Git credential setup failed for exec job: #{inspect(reason)}")
          []
      end
    else
      {:error, reason} ->
        Logger.debug("Git credential setup skipped for exec job: #{inspect(reason)}")
        []
    end
  end

  defp setup_git_credentials(_exec_job), do: []

  defp git_user_opts(scope, project_id) do
    case Integrations.get_connection(scope, project_id, "github_oauth") do
      {:ok, connection} ->
        meta = connection.provider_metadata || %{}
        name = meta["name"] || meta["username"]
        email = meta["email"] || github_noreply_email(meta["username"])

        [user_name: name, user_email: email]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      {:error, _} ->
        []
    end
  end

  defp github_noreply_email(nil), do: nil
  defp github_noreply_email(username), do: "#{username}@users.noreply.github.com"
end
