defmodule FizzWeb.SpritesLive.Show do
  use FizzWeb, :live_view

  alias Fizz.Sprites

  @impl true
  def mount(%{"workspace_id" => workspace_id, "sprite_id" => sprite_id}, _session, socket) do
    socket =
      socket
      |> assign(:workspace_id, workspace_id)
      |> assign(:sprite_id, sprite_id)
      |> assign(:sprite, nil)
      |> assign(:active_console, nil)
      |> assign(:job_form, to_form(%{"command" => "echo hello"}, as: :job))
      |> assign(:checkpoint_form, to_form(%{"comment" => ""}, as: :checkpoint))
      |> assign(:selected_job_id, nil)
      |> assign(:selected_job, nil)
      |> assign(:job_output, [])
      |> assign(:subscribed_job_ids, MapSet.new())
      |> stream(:jobs, [])
      |> stream(:services, [])
      |> stream(:checkpoints, [])

    {:ok, load_page(socket)}
  end

  @impl true
  def handle_params(%{"workspace_id" => workspace_id, "sprite_id" => sprite_id}, _uri, socket) do
    {:noreply,
     socket
     |> assign(:workspace_id, workspace_id)
     |> assign(:sprite_id, sprite_id)
     |> assign(:selected_job_id, nil)
     |> assign(:selected_job, nil)
     |> assign(:job_output, [])
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
           socket.assigns.workspace_id,
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
           socket.assigns.workspace_id,
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
     |> assign(:job_output, [])}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_page(socket)}
  end

  def handle_event("open_console", _params, socket) do
    case Sprites.open_console(
           socket.assigns.current_scope,
           socket.assigns.workspace_id,
           socket.assigns.sprite_id,
           %{"rows" => 30, "cols" => 120}
         ) do
      {:ok, console_session} ->
        {:noreply, assign(socket, :active_console, console_session)}

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
           socket.assigns.workspace_id,
           socket.assigns.sprite_id,
           socket.assigns.active_console.id
         ) do
      {:ok, _console_session} -> {:noreply, assign(socket, :active_console, nil)}
      {:error, _reason} -> {:noreply, assign(socket, :active_console, nil)}
    end
  end

  def handle_event("start_service", %{"name" => service_name}, socket) do
    case Sprites.start_service(
           socket.assigns.current_scope,
           socket.assigns.workspace_id,
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
           socket.assigns.workspace_id,
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
           socket.assigns.workspace_id,
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
             socket.assigns.workspace_id,
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
    if job_id == socket.assigns.selected_job_id do
      existing_seqs = MapSet.new(socket.assigns.job_output, & &1.seq)

      if MapSet.member?(existing_seqs, seq) do
        {:noreply, socket}
      else
        text = Base.decode64!(encoded_chunk)
        chunk = %{seq: seq, stream: stream_name, text: text}
        {:noreply, assign(socket, :job_output, socket.assigns.job_output ++ [chunk])}
      end
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
    |> assign(:job_output, output)
    |> subscribe_to_job_topic(job.id)
  end

  defp load_job_output(socket, job_id) do
    case Sprites.tail_job_logs(
           socket.assigns.current_scope,
           socket.assigns.workspace_id,
           socket.assigns.sprite_id,
           job_id,
           0,
           1000
         ) do
      {:ok, chunks} ->
        Enum.map(chunks, fn chunk ->
          %{seq: chunk.seq, stream: to_string(chunk.stream), text: chunk.chunk}
        end)

      {:error, _} ->
        []
    end
  end

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
           socket.assigns.workspace_id,
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
        |> redirect(to: ~p"/workspaces/#{socket.assigns.workspace_id}/sprites")

      {:error, reason} ->
        put_flash(socket, :error, "Could not load sprite: #{inspect(reason)}")
    end
  end

  defp load_jobs(socket) do
    case Sprites.list_sprite_jobs(
           socket.assigns.current_scope,
           socket.assigns.workspace_id,
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
           socket.assigns.workspace_id,
           socket.assigns.sprite_id
         ) do
      {:ok, services} -> stream(socket, :services, services, reset: true)
      {:error, _reason} -> socket
    end
  end

  defp load_checkpoints(socket) do
    case Sprites.list_sprite_checkpoints(
           socket.assigns.current_scope,
           socket.assigns.workspace_id,
           socket.assigns.sprite_id
         ) do
      {:ok, checkpoints} -> stream(socket, :checkpoints, checkpoints, reset: true)
      {:error, _reason} -> socket
    end
  end

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
