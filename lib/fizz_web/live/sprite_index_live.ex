defmodule FizzWeb.SpriteIndexLive do
  use FizzWeb, :live_view

  alias Fizz.Accounts.Scope
  alias Fizz.Sprites

  @impl true
  def mount(
        %{"organization_id" => organization_id, "workspace_id" => workspace_id},
        _session,
        socket
      ) do
    case Sprites.resolve_workspace_scope(
           socket.assigns.current_scope,
           organization_id,
           workspace_id
         ) do
      {:ok, sprite_scope} ->
        socket =
          socket
          |> assign(:page_title, "Sprites")
          |> assign(:organization_id, organization_id)
          |> assign(:workspace_id, workspace_id)
          |> assign(:sprite_scope, sprite_scope)
          |> assign(:sprite_form, sprite_form(%{"display_name" => "", "description" => ""}))
          |> assign(:sprite_error, nil)
          |> assign(:sprite_action_error, nil)
          |> load_sprites()

        {:ok, socket}

      {:error, _reason} ->
        socket =
          socket
          |> put_flash(:error, "Could not resolve workspace access for sprites.")
          |> redirect(to: ~p"/sprites")

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("validate_sprite", %{"sprite" => sprite_params}, socket) do
    {:noreply, assign(socket, :sprite_form, sprite_form(sprite_params))}
  end

  def handle_event("create_sprite", %{"sprite" => sprite_params}, socket) do
    case Sprites.create_sprite(socket.assigns.sprite_scope, sprite_params) do
      {:ok, _sprite} ->
        socket =
          socket
          |> assign(:sprite_error, nil)
          |> assign(:sprite_form, sprite_form(%{"display_name" => "", "description" => ""}))
          |> load_sprites()

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(:sprite_error, reason)
          |> assign(:sprite_form, sprite_form(sprite_params))

        {:noreply, socket}
    end
  end

  def handle_event("archive_sprite", %{"id" => sprite_id}, socket) do
    socket =
      case Sprites.archive_sprite(socket.assigns.sprite_scope, sprite_id) do
        {:ok, _sprite} ->
          socket
          |> assign(:sprite_action_error, nil)
          |> load_sprites()

        {:error, reason} ->
          assign(socket, :sprite_action_error, reason)
      end

    {:noreply, socket}
  end

  def handle_event("destroy_sprite", %{"id" => sprite_id}, socket) do
    socket =
      case Sprites.destroy_sprite(socket.assigns.sprite_scope, sprite_id) do
        {:ok, _sprite} ->
          socket
          |> assign(:sprite_action_error, nil)
          |> load_sprites()

        {:error, reason} ->
          assign(socket, :sprite_action_error, reason)
      end

    {:noreply, socket}
  end

  defp load_sprites(socket) do
    case Sprites.list_sprites(socket.assigns.sprite_scope) do
      {:ok, sprites} ->
        assign(socket, :sprites, sprites)

      {:error, _reason} ->
        assign(socket, :sprites, [])
    end
  end

  defp sprite_form(sprite_params) do
    to_form(sprite_params, as: :sprite)
  end

  defp sprite_error_message(:sprites_not_configured),
    do: "Sprites is not configured for this environment. Set SPRITES_API_KEY."

  defp sprite_error_message(:display_name_required),
    do: "A display name is required."

  defp sprite_error_message(:forbidden),
    do: "You are not allowed to perform this sprite action."

  defp sprite_error_message(:sprite_not_found),
    do: "Could not find this sprite in the current workspace."

  defp sprite_error_message(_reason),
    do: "Could not complete the sprite action right now."

  defp can_manage_sprites?(scope) do
    Scope.organization_admin?(scope) || Scope.workspace_admin?(scope)
  end
end
