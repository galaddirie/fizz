defmodule FizzWeb.SpritesLive.Show do
  use FizzWeb, :live_view

  alias Fizz.Integrations
  alias Fizz.Sprites

  @impl true
  def mount(%{"project_id" => project_id, "sprite_id" => sprite_id}, _session, socket) do
    socket =
      socket
      |> assign(:project_id, project_id)
      |> assign(:sprite_id, sprite_id)
      |> assign(:sprite, nil)
      |> assign(:active_console, nil)
      |> assign(:github_repo_lookup, %{})
      |> assign(:github_repos_error, nil)
      |> assign(:job_form, to_form(%{"command" => "echo hello"}, as: :job))
      |> assign(:checkpoint_form, to_form(%{"comment" => ""}, as: :checkpoint))
      |> assign(:selected_job_id, nil)
      |> assign(:selected_job, nil)
      |> assign(:job_output_seqs, MapSet.new())
      |> assign(:job_output_empty?, true)
      |> assign(:subscribed_job_ids, MapSet.new())
      |> stream(:jobs, [])
      |> stream(:services, [])
      |> stream(:checkpoints, [])
      |> stream(:job_output, [])
      |> stream(:github_repos, [])

    {:ok, load_page(socket)}
  end

  @impl true
  def handle_params(%{"project_id" => project_id, "sprite_id" => sprite_id}, _uri, socket) do
    {:noreply,
     socket
     |> assign(:project_id, project_id)
     |> assign(:sprite_id, sprite_id)
     |> assign(:selected_job_id, nil)
     |> assign(:selected_job, nil)
     |> clear_job_output()
     |> load_page()}
  end

  @impl true
  def handle_event("queue_job", %{"job" => params}, socket) do
    exec_spec = %{
      "command" => params["command"],
      "dir" => "/home/sprite"
    }

    case Sprites.queue_job(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           socket.assigns.sprite_id,
           exec_spec
         ) do
      {:ok, job} ->
        socket =
          socket
          |> put_flash(:info, "Job queued")
          |> assign(:job_form, to_form(%{"command" => ""}, as: :job))
          |> load_jobs()
          |> subscribe_to_job_topic(job.id)
          |> select_job(job)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not queue job: #{inspect(reason)}")}
    end
  end

  def handle_event("select_job", %{"id" => job_id}, socket) do
    case Sprites.inspect_job(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           socket.assigns.sprite_id,
           job_id
         ) do
      {:ok, job} ->
        {:noreply, select_job(socket, job)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not load job")}
    end
  end

  def handle_event("close_output", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_job_id, nil)
     |> assign(:selected_job, nil)
     |> clear_job_output()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_page(socket)}
  end

  def handle_event("refresh_repos", _params, %{assigns: %{active_console: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("refresh_repos", _params, socket) do
    {:noreply, load_github_repos(socket)}
  end

  def handle_event("open_console", _params, socket) do
    case Sprites.open_console(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           socket.assigns.sprite_id,
           %{"rows" => 30, "cols" => 120}
         ) do
      {:ok, console_session} ->
        {:noreply,
         socket
         |> assign(:active_console, console_session)
         |> load_github_repos()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not open console: #{inspect(reason)}")}
    end
  end

  def handle_event("close_console", _params, %{assigns: %{active_console: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("close_console", _params, socket) do
    case Sprites.close_console(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           socket.assigns.sprite_id,
           socket.assigns.active_console.id
         ) do
      {:ok, _console_session} ->
        {:noreply,
         socket
         |> assign(:active_console, nil)
         |> reset_github_repos()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:active_console, nil)
         |> reset_github_repos()}
    end
  end

  def handle_event("clone_repo", _params, %{assigns: %{active_console: nil}} = socket) do
    {:noreply, put_flash(socket, :error, "Open a console before cloning a repo")}
  end

  def handle_event("clone_repo", params, socket) when is_map(params) do
    repo_id =
      case params do
        %{"repo_id" => value} when is_binary(value) and byte_size(value) > 0 ->
          value

        %{"repo-id" => value} when is_binary(value) and byte_size(value) > 0 ->
          value

        _ ->
          nil
      end

    repo = repo_id && Map.get(socket.assigns.github_repo_lookup, repo_id)

    with repo_id when is_binary(repo_id) <- repo_id,
         %{} <- repo,
         clone_url when is_binary(clone_url) and byte_size(clone_url) > 0 <-
           Map.get(repo, :clone_url) do
      command = "git clone #{clone_url}\n"

      {:noreply,
       socket
       |> push_event("sprite_console_run_command", %{
         console_id: socket.assigns.active_console.id,
         command: command
       })
       |> put_flash(:info, "Cloning #{Map.get(repo, :full_name, "repository")}")}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Repository unavailable")}

      _ ->
        {:noreply, put_flash(socket, :error, "Repository has no clone URL")}
    end
  end

  def handle_event("start_service", %{"name" => service_name}, socket) do
    case Sprites.start_service(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           socket.assigns.sprite_id,
           service_name
         ) do
      {:ok, _service} ->
        {:noreply, socket |> put_flash(:info, "Service started") |> load_services()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start service: #{inspect(reason)}")}
    end
  end

  def handle_event("stop_service", %{"name" => service_name}, socket) do
    case Sprites.stop_service(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           socket.assigns.sprite_id,
           service_name
         ) do
      {:ok, _service} ->
        {:noreply, socket |> put_flash(:info, "Service stopped") |> load_services()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not stop service: #{inspect(reason)}")}
    end
  end

  def handle_event("capture_checkpoint", %{"checkpoint" => params}, socket) do
    case Sprites.capture_checkpoint(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           socket.assigns.sprite_id,
           %{"comment" => params["comment"]}
         ) do
      {:ok, _checkpoint} ->
        {:noreply,
         socket
         |> put_flash(:info, "Checkpoint created")
         |> assign(:checkpoint_form, to_form(%{"comment" => ""}, as: :checkpoint))
         |> load_checkpoints()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create checkpoint: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "sprite_logs:" <> job_id,
          event: "job_state",
          payload: %{state: _state_str}
        },
        socket
      ) do
    socket =
      case Sprites.inspect_job(
             socket.assigns.current_scope,
             socket.assigns.project_id,
             socket.assigns.sprite_id,
             job_id
           ) do
        {:ok, job} ->
          socket = stream_insert(socket, :jobs, job)

          if socket.assigns.selected_job_id == job.id do
            assign(socket, :selected_job, job)
          else
            socket
          end

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "sprite_logs:" <> job_id,
          event: "chunk",
          payload: %{seq: seq, stream: stream_name, chunk: encoded_chunk}
        },
        socket
      ) do
    if job_id == socket.assigns.selected_job_id and
         not MapSet.member?(socket.assigns.job_output_seqs, seq) do
      text = Base.decode64!(encoded_chunk)
      chunk = output_chunk(seq, stream_name, text)

      {:noreply,
       socket
       |> assign(:job_output_seqs, MapSet.put(socket.assigns.job_output_seqs, seq))
       |> assign(:job_output_empty?, false)
       |> stream_insert(:job_output, chunk)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{}, socket) do
    {:noreply, socket}
  end

  defp select_job(socket, job) do
    output = load_job_output(socket, job.id)

    socket
    |> assign(:selected_job_id, job.id)
    |> assign(:selected_job, job)
    |> assign_job_output(output)
    |> subscribe_to_job_topic(job.id)
  end

  defp load_job_output(socket, job_id) do
    case Sprites.tail_job_logs(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           socket.assigns.sprite_id,
           job_id,
           0,
           1000
         ) do
      {:ok, chunks} ->
        Enum.map(chunks, fn chunk ->
          output_chunk(chunk.seq, to_string(chunk.stream), chunk.chunk)
        end)

      {:error, _} ->
        []
    end
  end

  defp output_chunk(seq, stream_name, text) do
    %{id: "job-output-#{seq}", seq: seq, stream: stream_name, text: text}
  end

  defp assign_job_output(socket, output) do
    socket
    |> assign(:job_output_seqs, MapSet.new(output, & &1.seq))
    |> assign(:job_output_empty?, output == [])
    |> stream(:job_output, output, reset: true)
  end

  defp clear_job_output(socket), do: assign_job_output(socket, [])

  defp subscribe_to_job_topic(socket, job_id) do
    if connected?(socket) and not MapSet.member?(socket.assigns.subscribed_job_ids, job_id) do
      FizzWeb.Endpoint.subscribe("sprite_logs:#{job_id}")

      assign(
        socket,
        :subscribed_job_ids,
        MapSet.put(socket.assigns.subscribed_job_ids, job_id)
      )
    else
      socket
    end
  end

  defp subscribe_to_job_topics(socket, jobs) do
    Enum.reduce(jobs, socket, fn job, acc ->
      subscribe_to_job_topic(acc, job.id)
    end)
  end

  defp load_page(socket) do
    socket
    |> load_sprite()
    |> load_jobs()
    |> load_services()
    |> load_checkpoints()
  end

  defp load_sprite(socket) do
    case Sprites.inspect_sprite(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           socket.assigns.sprite_id
         ) do
      {:ok, sprite} ->
        socket
        |> assign(:sprite, sprite)
        |> assign(:page_title, "Sprite #{sprite.name}")

      {:error, :forbidden} ->
        socket
        |> put_flash(:error, "You do not have access to this sprite")
        |> redirect(to: ~p"/")

      {:error, :sprite_not_found} ->
        socket
        |> put_flash(:error, "Sprite not found")
        |> redirect(to: ~p"/projects/#{socket.assigns.project_id}/sprites")

      {:error, reason} ->
        put_flash(socket, :error, "Could not load sprite: #{inspect(reason)}")
    end
  end

  defp load_jobs(socket) do
    case Sprites.list_sprite_jobs(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           socket.assigns.sprite_id
         ) do
      {:ok, jobs} ->
        socket
        |> stream(:jobs, jobs, reset: true)
        |> subscribe_to_job_topics(jobs)

      {:error, _reason} ->
        socket
    end
  end

  defp load_services(socket) do
    case Sprites.list_sprite_services(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           socket.assigns.sprite_id
         ) do
      {:ok, services} -> stream(socket, :services, services, reset: true)
      {:error, _reason} -> socket
    end
  end

  defp load_checkpoints(socket) do
    case Sprites.list_sprite_checkpoints(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           socket.assigns.sprite_id
         ) do
      {:ok, checkpoints} -> stream(socket, :checkpoints, checkpoints, reset: true)
      {:error, _reason} -> socket
    end
  end

  defp load_github_repos(socket) do
    case Integrations.list_repos(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           "github_oauth",
           per_page: 100,
           sort: "updated",
           visibility: "all"
         ) do
      {:ok, repos} ->
        socket
        |> assign(:github_repo_lookup, Map.new(repos, &{to_string(&1.id), &1}))
        |> assign(:github_repos_error, nil)
        |> stream(:github_repos, repos, reset: true)

      {:error, reason} ->
        socket
        |> reset_github_repos()
        |> assign(:github_repos_error, format_github_repo_error(reason))
    end
  end

  defp reset_github_repos(socket) do
    socket
    |> assign(:github_repo_lookup, %{})
    |> assign(:github_repos_error, nil)
    |> stream(:github_repos, [], reset: true)
  end

  defp format_github_repo_error(:unauthorized),
    do: "GitHub access expired. Reconnect your GitHub integration."

  defp format_github_repo_error(:forbidden),
    do: "GitHub denied repo access. Confirm your GitHub scopes."

  defp format_github_repo_error({:provider_inactive, _reason}),
    do: "GitHub integration is not active in this project."

  defp format_github_repo_error(:organization_not_found),
    do: "project is missing an organization context for GitHub."

  defp format_github_repo_error(reason),
    do: "Could not load repositories: #{inspect(reason)}"

  # -- View helpers --

  defp job_display_command(job) do
    case job.args do
      ["-lc", cmd | _] -> cmd
      ["-c", cmd | _] -> cmd
      _ -> Enum.join([job.command | job.args], " ")
    end
  end

  defp job_state_badge_class(state) do
    case state do
      :queued -> "badge-ghost"
      :running -> "badge-info"
      :succeeded -> "badge-success"
      :failed -> "badge-error"
      :timed_out -> "badge-warning"
      :canceled -> "badge-ghost"
      :system_error -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  defp terminal_state?(state) do
    state in [:succeeded, :failed, :timed_out, :canceled, :system_error]
  end
end
