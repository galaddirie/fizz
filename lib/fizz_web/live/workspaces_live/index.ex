defmodule FizzWeb.WorkspacesLive.Index do
  use FizzWeb, :live_view

  alias Fizz.Accounts

  @impl true
  def mount(_params, _session, socket) do
    organizations = Accounts.ensure_personal_organization(socket.assigns.current_scope)
    selected_organization_id = default_organization_id(organizations)

    socket =
      socket
      |> assign(:page_title, "Workspaces")
      |> assign(:organizations, organizations)
      |> assign(:organization_options, organization_options(organizations))
      |> assign(:selected_organization_id, selected_organization_id)
      |> assign(:organization_form, organization_form(selected_organization_id))
      |> assign(:create_form, to_form(%{"name" => "", "description" => ""}, as: :workspace))
      |> assign(:workspace_scope, nil)
      |> assign(:workspace_error, nil)
      |> stream(:workspaces, [])

    {:ok, load_workspaces(socket)}
  end

  @impl true
  def handle_event(
        "change_organization",
        %{"organization" => %{"organization_id" => organization_id}},
        socket
      ) do
    selected_organization_id =
      validate_selected_organization_id(organization_id, socket.assigns.organizations)

    {:noreply,
     socket
     |> assign(:selected_organization_id, selected_organization_id)
     |> assign(:organization_form, organization_form(selected_organization_id))
     |> assign(:workspace_scope, nil)
     |> load_workspaces()}
  end

  def handle_event("validate_create_workspace", %{"workspace" => params}, socket) do
    {:noreply, assign(socket, :create_form, to_form(params, as: :workspace))}
  end

  def handle_event("create_workspace", %{"workspace" => params}, socket) do
    case socket.assigns.workspace_scope do
      nil ->
        {:noreply,
         put_flash(socket, :error, "Select an organization before creating a workspace.")}

      scope ->
        case Accounts.create_workspace(scope, params) do
          {:ok, _workspace} ->
            {:noreply,
             socket
             |> put_flash(:info, "Workspace created")
             |> assign(
               :create_form,
               to_form(%{"name" => "", "description" => ""}, as: :workspace)
             )
             |> load_workspaces()}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :create_form, to_form(changeset, as: :workspace))}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not create workspace: #{inspect(reason)}")}
        end
    end
  end

  defp load_workspaces(%{assigns: %{selected_organization_id: nil}} = socket) do
    socket
    |> assign(:workspace_scope, nil)
    |> assign(:workspace_error, :no_organization)
    |> stream(:workspaces, [], reset: true)
  end

  defp load_workspaces(socket) do
    case Accounts.build_scope(
           socket.assigns.current_scope,
           socket.assigns.selected_organization_id
         ) do
      {:ok, workspace_scope} ->
        case Accounts.list_workspaces(workspace_scope) do
          {:ok, workspaces} ->
            socket
            |> assign(:workspace_scope, workspace_scope)
            |> assign(:workspace_error, nil)
            |> stream(:workspaces, workspaces, reset: true)

          {:error, reason} ->
            socket
            |> assign(:workspace_scope, nil)
            |> assign(:workspace_error, reason)
            |> stream(:workspaces, [], reset: true)
        end

      {:error, reason} ->
        socket
        |> assign(:workspace_scope, nil)
        |> assign(:workspace_error, reason)
        |> stream(:workspaces, [], reset: true)
    end
  end

  defp organization_form(selected_organization_id) do
    to_form(%{"organization_id" => selected_organization_id || ""}, as: :organization)
  end

  defp default_organization_id([%{organization_id: organization_id} | _]), do: organization_id
  defp default_organization_id(_organizations), do: nil

  defp organization_options(organizations) do
    Enum.map(organizations, fn organization ->
      {organization.organization_name, organization.organization_id}
    end)
  end

  defp validate_selected_organization_id(requested_organization_id, organizations) do
    if Enum.any?(organizations, fn organization ->
         organization.organization_id == requested_organization_id
       end) do
      requested_organization_id
    else
      default_organization_id(organizations)
    end
  end

  defp workspace_error_message(:no_organization) do
    "No organization could be resolved for this account."
  end

  defp workspace_error_message(:missing_workos_user_id) do
    "This account is missing a WorkOS user id."
  end

  defp workspace_error_message(:forbidden) do
    "You do not have workspace access in the selected organization."
  end

  defp workspace_error_message(_reason) do
    "Could not load workspaces for this organization right now."
  end
end
