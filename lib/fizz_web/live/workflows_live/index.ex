defmodule FizzWeb.WorkflowsLive.Index do
  use FizzWeb, :live_view

  alias Fizz.Accounts
  alias Fizz.Workflows

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    socket =
      socket
      |> assign(:project_id, project_id)
      |> assign(:project, nil)
      |> assign(:resolve_project_scope, nil)
      |> assign(:page_title, "Workflows")
      |> assign(:definitions_empty?, true)
      |> stream(:definitions, [])

    {:ok, load_project_and_definitions(socket)}
  end

  @impl true
  def handle_event("create_workflow", _params, socket) do
    scope = socket.assigns.resolve_project_scope

    case Workflows.create_definition(scope, %{name: "Untitled Workflow"}) do
      {:ok, %{definition: definition}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workflow created")
         |> push_navigate(
           to: ~p"/projects/#{socket.assigns.project_id}/workflows/#{definition.id}/edit"
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create workflow: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("open_workflow", %{"definition_id" => definition_id}, socket) do
    {:noreply,
     push_navigate(socket,
       to: ~p"/projects/#{socket.assigns.project_id}/workflows/#{definition_id}/edit"
     )}
  end

  defp load_project_and_definitions(socket) do
    case Accounts.build_scope_for_project(
           socket.assigns.current_scope,
           socket.assigns.project_id
         ) do
      {:ok, resolve_project_scope} ->
        project =
          resolve_project_scope.project || Accounts.get_project(socket.assigns.project_id)

        if project do
          case Workflows.list_definitions(resolve_project_scope) do
            {:ok, definitions} ->
              definitions = sort_definitions(definitions)

              socket
              |> assign(:resolve_project_scope, resolve_project_scope)
              |> assign(:project, project)
              |> assign(:page_title, "#{project.name} — Workflows")
              |> assign(:definitions_empty?, definitions == [])
              |> stream(:definitions, definitions, reset: true)

            {:error, _reason} ->
              socket
              |> assign(:resolve_project_scope, resolve_project_scope)
              |> assign(:project, project)
              |> assign(:definitions_empty?, true)
              |> stream(:definitions, [], reset: true)
          end
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

  defp sort_definitions(definitions) do
    Enum.sort_by(definitions, & &1.updated_at, {:desc, DateTime})
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: ""

  defp formatted_timestamp(nil), do: ""

  defp formatted_timestamp(dt) do
    Calendar.strftime(dt, "%b %d, %Y")
  end
end
