defmodule FizzWeb.WorkspacesLive.Index do
  use FizzWeb, :live_view

  alias Fizz.Workspaces

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    socket =
      socket
      |> assign(:project_id, project_id)
      |> assign(:page_title, "Workspaces")
      |> assign(:create_form, to_form(%{"name" => ""}, as: :workspace))
      |> stream(:workspaces, [])

    {:ok, load_project_workspaces(socket)}
  end

  @impl true
  def handle_params(%{"project_id" => project_id}, _uri, socket) do
    {:noreply, socket |> assign(:project_id, project_id) |> load_project_workspaces()}
  end

  @impl true
  def handle_event("validate_create_workspace", %{"workspace" => params}, socket) do
    {:noreply, assign(socket, :create_form, to_form(params, as: :workspace))}
  end

  def handle_event("create_workspace", %{"workspace" => params}, socket) do
    case Workspaces.create_workspace(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           params
         ) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workspace created")
         |> assign(:create_form, to_form(%{"name" => ""}, as: :workspace))
         |> load_project_workspaces()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create workspace: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_workspace", %{"id" => workspace_id}, socket) do
    case Workspaces.delete_workspace(
           socket.assigns.current_scope,
           socket.assigns.project_id,
           workspace_id
         ) do
      {:ok, _workspace} ->
        {:noreply, socket |> put_flash(:info, "Workspace deleted") |> load_project_workspaces()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete workspace: #{inspect(reason)}")}
    end
  end

  defp load_project_workspaces(socket) do
    case Workspaces.list_project_workspaces(
           socket.assigns.current_scope,
           socket.assigns.project_id
         ) do
      {:ok, workspaces} ->
        socket
        |> assign(:resolve_project_scope, resolve_project_scope(socket))
        |> stream(:workspaces, workspaces, reset: true)

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
        |> put_flash(:error, "Could not load workspaces: #{inspect(reason)}")
    end
  end

  defp resolve_project_scope(socket) do
    case Workspaces.resolve_project_scope(
           socket.assigns.current_scope,
           socket.assigns.project_id
         ) do
      {:ok, resolved_scope} -> resolved_scope
      _ -> socket.assigns.current_scope
    end
  end
end
