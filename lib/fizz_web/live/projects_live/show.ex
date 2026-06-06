defmodule FizzWeb.ProjectsLive.Show do
  use FizzWeb, :live_view

  alias Fizz.Accounts

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    socket =
      socket
      |> assign(:project_id, project_id)
      |> assign(:project, nil)
      |> assign(:resolve_project_scope, nil)
      |> assign(:page_title, "Project")

    {:ok, load_project(socket)}
  end

  @impl true
  def handle_params(%{"project_id" => project_id}, _uri, socket) do
    {:noreply, socket |> assign(:project_id, project_id) |> load_project()}
  end

  defp load_project(socket) do
    case Accounts.build_scope_for_project(
           socket.assigns.current_scope,
           socket.assigns.project_id
         ) do
      {:ok, resolve_project_scope} ->
        project =
          resolve_project_scope.project || Accounts.get_project(socket.assigns.project_id)

        if project do
          socket
          |> assign(:resolve_project_scope, resolve_project_scope)
          |> assign(:project, project)
          |> assign(:page_title, project.name)
        else
          socket
          |> put_flash(:error, "Project not found")
          |> redirect(to: ~p"/projects")
        end

      {:error, :project_not_found} ->
        socket
        |> put_flash(:error, "Project not found")
        |> redirect(to: ~p"/projects")

      {:error, :forbidden} ->
        socket
        |> put_flash(:error, "You do not have access to this project")
        |> redirect(to: ~p"/projects")

      {:error, reason} ->
        socket
        |> put_flash(:error, "Could not load project: #{inspect(reason)}")
        |> redirect(to: ~p"/projects")
    end
  end
end
