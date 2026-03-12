defmodule FizzWeb.ProjectsLive.Index do
  use FizzWeb, :live_view

  alias Fizz.Accounts

  @impl true
  def mount(_params, _session, socket) do
    organizations = Accounts.ensure_personal_organization(socket.assigns.current_scope)
    selected_organization_id = default_organization_id(organizations)

    socket =
      socket
      |> assign(:page_title, "Projects")
      |> assign(:organizations, organizations)
      |> assign(:organization_options, organization_options(organizations))
      |> assign(:selected_organization_id, selected_organization_id)
      |> assign(:organization_form, organization_form(selected_organization_id))
      |> assign(:create_form, to_form(%{"name" => "", "description" => ""}, as: :project))
      |> assign(:resolve_project_scope, nil)
      |> assign(:project_error, nil)
      |> stream(:projects, [])

    {:ok, load_projects(socket)}
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
     |> assign(:resolve_project_scope, nil)
     |> load_projects()}
  end

  def handle_event("validate_create_project", %{"project" => params}, socket) do
    {:noreply, assign(socket, :create_form, to_form(params, as: :project))}
  end

  def handle_event("create_project", %{"project" => params}, socket) do
    case socket.assigns.resolve_project_scope do
      nil ->
        {:noreply, put_flash(socket, :error, "Select an organization before creating a project.")}

      scope ->
        case Accounts.create_project(scope, params) do
          {:ok, _project} ->
            {:noreply,
             socket
             |> put_flash(:info, "Project created")
             |> assign(
               :create_form,
               to_form(%{"name" => "", "description" => ""}, as: :project)
             )
             |> load_projects()}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :create_form, to_form(changeset, as: :project))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not create project: #{inspect(reason)}")}
        end
    end
  end

  defp load_projects(%{assigns: %{selected_organization_id: nil}} = socket) do
    socket
    |> assign(:resolve_project_scope, nil)
    |> assign(:project_error, :no_organization)
    |> stream(:projects, [], reset: true)
  end

  defp load_projects(socket) do
    case Accounts.build_scope(
           socket.assigns.current_scope,
           socket.assigns.selected_organization_id
         ) do
      {:ok, resolve_project_scope} ->
        case Accounts.list_projects(resolve_project_scope) do
          {:ok, projects} ->
            socket
            |> assign(:resolve_project_scope, resolve_project_scope)
            |> assign(:project_error, nil)
            |> stream(:projects, projects, reset: true)

          {:error, reason} ->
            socket
            |> assign(:resolve_project_scope, nil)
            |> assign(:project_error, reason)
            |> stream(:projects, [], reset: true)
        end

      {:error, reason} ->
        socket
        |> assign(:resolve_project_scope, nil)
        |> assign(:project_error, reason)
        |> stream(:projects, [], reset: true)
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

  defp project_error_message(:no_organization) do
    "No organization could be resolved for this account."
  end

  defp project_error_message(:missing_workos_user_id) do
    "This account is missing a WorkOS user id."
  end

  defp project_error_message(:forbidden) do
    "You do not have project access in the selected organization."
  end

  defp project_error_message(_reason) do
    "Could not load projects for this organization right now."
  end
end
