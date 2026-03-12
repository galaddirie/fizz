defmodule FizzWeb.SpritesLive.Index do
  use FizzWeb, :live_view

  alias Fizz.Sprites

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    socket =
      socket
      |> assign(:project_id, project_id)
      |> assign(:page_title, "Sprites")
      |> assign(:create_form, to_form(%{"name" => ""}, as: :sprite))
      |> stream(:sprites, [])

    {:ok, load_project_sprites(socket)}
  end

  @impl true
  def handle_params(%{"project_id" => project_id}, _uri, socket) do
    {:noreply, socket |> assign(:project_id, project_id) |> load_project_sprites()}
  end

  @impl true
  def handle_event("validate_create_sprite", %{"sprite" => params}, socket) do
    {:noreply, assign(socket, :create_form, to_form(params, as: :sprite))}
  end

  def handle_event("provision_sprite", %{"sprite" => params}, socket) do
    case Sprites.provision_sprite(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           params
         ) do
      {:ok, _sprite} ->
        {:noreply,
         socket
         |> put_flash(:info, "Sprite created")
         |> assign(:create_form, to_form(%{"name" => ""}, as: :sprite))
         |> load_project_sprites()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create sprite: #{inspect(reason)}")}
    end
  end

  def handle_event("terminate_sprite", %{"id" => sprite_id}, socket) do
    case Sprites.terminate_sprite(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           sprite_id
         ) do
      {:ok, _sprite} ->
        {:noreply, socket |> put_flash(:info, "Sprite deleted") |> load_project_sprites()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete sprite: #{inspect(reason)}")}
    end
  end

  defp load_project_sprites(socket) do
    case Sprites.list_project_sprites(socket.assigns.current_scope, socket.assigns.project_id) do
      {:ok, sprites} ->
        socket
        |> assign(:resolve_project_scope, resolve_project_scope(socket))
        |> stream(:sprites, sprites, reset: true)

      {:error, :forbidden} ->
        socket
        |> put_flash(:error, "You do not have access to this project")
        |> redirect(to: ~p"/")

      {:error, :project_not_found} ->
        socket
        |> put_flash(:error, "project not found")
        |> redirect(to: ~p"/")

      {:error, reason} ->
        socket
        |> put_flash(:error, "Could not load sprites: #{inspect(reason)}")
    end
  end

  defp resolve_project_scope(socket) do
    case Sprites.resolve_project_scope(
           socket.assigns.current_scope,
           socket.assigns.project_id
         ) do
      {:ok, resolved_scope} -> resolved_scope
      _ -> socket.assigns.current_scope
    end
  end
end
