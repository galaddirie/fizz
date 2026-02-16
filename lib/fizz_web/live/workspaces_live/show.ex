defmodule FizzWeb.WorkspacesLive.Show do
  use FizzWeb, :live_view

  alias Fizz.Accounts

  @impl true
  def mount(%{"workspace_id" => workspace_id}, _session, socket) do
    socket =
      socket
      |> assign(:workspace_id, workspace_id)
      |> assign(:workspace, nil)
      |> assign(:resolve_workspace_scope, nil)
      |> assign(:page_title, "Workspace")

    {:ok, load_workspace(socket)}
  end

  @impl true
  def handle_params(%{"workspace_id" => workspace_id}, _uri, socket) do
    {:noreply, socket |> assign(:workspace_id, workspace_id) |> load_workspace()}
  end

  defp load_workspace(socket) do
    case Accounts.build_scope_for_workspace(
           socket.assigns.current_scope,
           socket.assigns.workspace_id
         ) do
      {:ok, resolve_workspace_scope} ->
        workspace =
          resolve_workspace_scope.workspace || Accounts.get_workspace(socket.assigns.workspace_id)

        if workspace do
          socket
          |> assign(:resolve_workspace_scope, resolve_workspace_scope)
          |> assign(:workspace, workspace)
          |> assign(:page_title, workspace.name)
        else
          socket
          |> put_flash(:error, "Workspace not found")
          |> redirect(to: ~p"/workspaces")
        end

      {:error, :workspace_not_found} ->
        socket
        |> put_flash(:error, "Workspace not found")
        |> redirect(to: ~p"/workspaces")

      {:error, :forbidden} ->
        socket
        |> put_flash(:error, "You do not have access to this workspace")
        |> redirect(to: ~p"/workspaces")

      {:error, reason} ->
        socket
        |> put_flash(:error, "Could not load workspace: #{inspect(reason)}")
        |> redirect(to: ~p"/workspaces")
    end
  end
end
