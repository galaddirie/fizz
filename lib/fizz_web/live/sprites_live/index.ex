defmodule FizzWeb.SpritesLive.Index do
  use FizzWeb, :live_view

  alias Fizz.Sprites

  @impl true
  def mount(%{"workspace_id" => workspace_id}, _session, socket) do
    socket =
      socket
      |> assign(:workspace_id, workspace_id)
      |> assign(:page_title, "Sprites")
      |> assign(:create_form, to_form(%{"name" => ""}, as: :sprite))
      |> stream(:sprites, [])

    {:ok, load_workspace_sprites(socket)}
  end

  @impl true
  def handle_params(%{"workspace_id" => workspace_id}, _uri, socket) do
    {:noreply, socket |> assign(:workspace_id, workspace_id) |> load_workspace_sprites()}
  end

  @impl true
  def handle_event("validate_create_sprite", %{"sprite" => params}, socket) do
    {:noreply, assign(socket, :create_form, to_form(params, as: :sprite))}
  end

  def handle_event("provision_sprite", %{"sprite" => params}, socket) do
    case Sprites.provision_sprite(
           socket.assigns.current_scope,
           socket.assigns.workspace_id,
           params
         ) do
      {:ok, _sprite} ->
        {:noreply,
         socket
         |> put_flash(:info, "Sprite created")
         |> assign(:create_form, to_form(%{"name" => ""}, as: :sprite))
         |> load_workspace_sprites()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create sprite: #{inspect(reason)}")}
    end
  end

  def handle_event("terminate_sprite", %{"id" => sprite_id}, socket) do
    case Sprites.terminate_sprite(
           socket.assigns.current_scope,
           socket.assigns.workspace_id,
           sprite_id
         ) do
      {:ok, _sprite} ->
        {:noreply, socket |> put_flash(:info, "Sprite deleted") |> load_workspace_sprites()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete sprite: #{inspect(reason)}")}
    end
  end

  defp load_workspace_sprites(socket) do
    case Sprites.list_workspace_sprites(socket.assigns.current_scope, socket.assigns.workspace_id) do
      {:ok, sprites} ->
        socket
        |> assign(:resolve_workspace_scope, resolve_workspace_scope(socket))
        |> stream(:sprites, sprites, reset: true)

      {:error, :forbidden} ->
        socket
        |> put_flash(:error, "You do not have access to this workspace")
        |> redirect(to: ~p"/")

      {:error, :workspace_not_found} ->
        socket
        |> put_flash(:error, "Workspace not found")
        |> redirect(to: ~p"/")

      {:error, reason} ->
        socket
        |> put_flash(:error, "Could not load sprites: #{inspect(reason)}")
    end
  end

  defp resolve_workspace_scope(socket) do
    case Sprites.resolve_workspace_scope(
           socket.assigns.current_scope,
           socket.assigns.workspace_id
         ) do
      {:ok, resolved_scope} -> resolved_scope
      _ -> socket.assigns.current_scope
    end
  end
end
