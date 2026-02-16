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
     |> load_page()}
  end

  @impl true
  def handle_event("enqueue_job", %{"job" => params}, socket) do
    exec_spec = %{
      "command" => "/bin/sh",
      "args" => ["-lc", params["command"]],
      "dir" => "/"
    }

    case Sprites.enqueue_job(
           socket.assigns.current_scope,
           socket.assigns.workspace_id,
           socket.assigns.sprite_id,
           exec_spec
         ) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Job queued")
         |> assign(:job_form, to_form(%{"command" => ""}, as: :job))
         |> load_jobs()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not queue job: #{inspect(reason)}")}
    end
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

  def handle_event("create_checkpoint", %{"checkpoint" => params}, socket) do
    case Sprites.create_checkpoint(
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

  defp load_page(socket) do
    socket
    |> load_sprite()
    |> load_jobs()
    |> load_services()
    |> load_checkpoints()
  end

  defp load_sprite(socket) do
    case Sprites.get_sprite(
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
    case Sprites.list_jobs(
           socket.assigns.current_scope,
           socket.assigns.workspace_id,
           socket.assigns.sprite_id
         ) do
      {:ok, jobs} -> stream(socket, :jobs, jobs, reset: true)
      {:error, _reason} -> socket
    end
  end

  defp load_services(socket) do
    case Sprites.list_services(
           socket.assigns.current_scope,
           socket.assigns.workspace_id,
           socket.assigns.sprite_id
         ) do
      {:ok, services} -> stream(socket, :services, services, reset: true)
      {:error, _reason} -> socket
    end
  end

  defp load_checkpoints(socket) do
    case Sprites.list_checkpoints(
           socket.assigns.current_scope,
           socket.assigns.workspace_id,
           socket.assigns.sprite_id
         ) do
      {:ok, checkpoints} -> stream(socket, :checkpoints, checkpoints, reset: true)
      {:error, _reason} -> socket
    end
  end
end
