defmodule FizzWeb.WorkspaceLogsChannel do
  use FizzWeb, :channel

  alias Fizz.Workspaces
  alias Fizz.Workspaces.ExecJob

  @impl true
  def join("workspace_logs:" <> job_id, _payload, socket) do
    case Workspaces.authorize_job_topic(socket.assigns.current_scope, job_id) do
      {:ok, exec_job} ->
        {:ok, %{job: job_json(exec_job)}, assign(socket, :job_id, exec_job.id)}

      {:error, reason} ->
        {:error, %{reason: format_reason(reason)}}
    end
  end

  @spec job_json(ExecJob.t()) :: map()
  defp job_json(%ExecJob{} = job) do
    %{
      id: job.id,
      workspace_id: job.workspace_id,
      project_id: job.project_id,
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

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
