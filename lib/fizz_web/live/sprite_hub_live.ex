defmodule FizzWeb.SpriteHubLive do
  use FizzWeb, :live_view

  alias Fizz.Accounts

  @impl true
  def mount(params, _session, socket) do
    organizations = Accounts.list_user_workos_organizations(socket.assigns.current_scope)
    selected_organization_id = params["organization_id"] || default_organization_id(organizations)

    socket =
      socket
      |> assign(:page_title, "Sprites")
      |> assign(:organizations, organizations)
      |> assign(:organization_options, organization_options(organizations))
      |> assign(:selected_organization_id, selected_organization_id)
      |> assign(:organization_form, organization_form(selected_organization_id))
      |> assign(:organization_scope, nil)
      |> assign(:workspace_form, workspace_form(%{"name" => "", "description" => ""}))
      |> assign(:workspace_error, nil)
      |> load_selected_organization()

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "change_organization",
        %{"organization" => %{"organization_id" => organization_id}},
        socket
      ) do
    selected_organization_id =
      validate_selected_organization_id(organization_id, socket.assigns.organizations)

    socket =
      socket
      |> assign(:selected_organization_id, selected_organization_id)
      |> assign(:organization_form, organization_form(selected_organization_id))
      |> assign(:workspace_error, nil)
      |> load_selected_organization()

    {:noreply, socket}
  end

  def handle_event("validate_workspace", %{"workspace" => workspace_params}, socket) do
    {:noreply, assign(socket, :workspace_form, workspace_form(workspace_params))}
  end

  def handle_event("create_workspace", %{"workspace" => workspace_params}, socket) do
    case socket.assigns.organization_scope do
      nil ->
        {:noreply, assign(socket, :workspace_error, :organization_scope_unavailable)}

      organization_scope ->
        case Accounts.create_workspace(organization_scope, workspace_params) do
          {:ok, workspace} ->
            target_path =
              ~p"/org/#{organization_scope.organization_id}/workspaces/#{workspace.id}/sprites"

            {:noreply, push_navigate(socket, to: target_path)}

          {:error, reason} ->
            socket =
              socket
              |> assign(:workspace_error, reason)
              |> assign(:workspace_form, workspace_form(workspace_params))

            {:noreply, socket}
        end
    end
  end

  defp load_selected_organization(socket) do
    case socket.assigns.selected_organization_id do
      nil ->
        assign(socket, :organization_scope, nil)

      organization_id ->
        case Accounts.build_scope(socket.assigns.current_scope, organization_id) do
          {:ok, organization_scope} ->
            case Accounts.list_workspaces(organization_scope) do
              {:ok, [workspace | _rest]} ->
                redirect(
                  socket,
                  to: ~p"/org/#{organization_id}/workspaces/#{workspace.id}/sprites"
                )

              {:ok, []} ->
                socket
                |> assign(:organization_scope, organization_scope)
                |> assign(:workspace_error, nil)

              {:error, reason} ->
                socket
                |> assign(:organization_scope, organization_scope)
                |> assign(:workspace_error, reason)
            end

          {:error, reason} ->
            socket
            |> assign(:organization_scope, nil)
            |> assign(:workspace_error, reason)
        end
    end
  end

  defp workspace_form(workspace_params) do
    to_form(workspace_params, as: :workspace)
  end

  defp organization_form(selected_organization_id) do
    to_form(%{"organization_id" => selected_organization_id || ""}, as: :organization)
  end

  defp default_organization_id([%{organization_id: organization_id} | _]), do: organization_id
  defp default_organization_id(_), do: nil

  defp organization_options(organizations) do
    Enum.map(organizations, fn organization ->
      {"#{organization.organization_name} (#{organization.organization_id})",
       organization.organization_id}
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

  defp workspace_error_message(:organization_scope_unavailable),
    do: "Choose an organization before creating a workspace."

  defp workspace_error_message(:forbidden),
    do: "Your account does not have permission to create a workspace in this organization."

  defp workspace_error_message(_reason),
    do: "Could not create the workspace right now."
end
