defmodule FizzWeb.SpriteLogsChannel do
  use FizzWeb, :channel

  alias Fizz.Sprites
  alias FizzWeb.Api.Helpers

  @impl true
  def join("sprite_logs:" <> job_id, _payload, socket) do
    case Sprites.authorize_job_topic(socket.assigns.current_scope, job_id) do
      {:ok, exec_job} ->
        {:ok, %{job: Helpers.job_json(exec_job)}, assign(socket, :job_id, exec_job.id)}

      {:error, reason} ->
        {:error, %{reason: to_string(reason)}}
    end
  end
end
