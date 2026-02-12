defmodule FizzWeb.UserManagementLive do
  use FizzWeb, :live_view

  alias Fizz.Accounts

  @tabs [
    %{
      id: "profile",
      title: "Profile",
      icon: "hero-user",
      widget_name: "user-profile"
    },
    %{
      id: "security",
      title: "Security",
      icon: "hero-shield-check",
      widget_name: "user-security"
    },
    %{
      id: "connections",
      title: "Connections",
      icon: "hero-link",
      widget_name: "pipes"
    },
    %{
      id: "sessions",
      title: "Sessions",
      icon: "hero-computer-desktop",
      widget_name: "user-sessions"
    },
    %{
      id: "members",
      title: "Members",
      icon: "hero-user-group",
      widget_name: "users-management"
    },
    %{
      id: "api-keys",
      title: "API Keys",
      icon: "hero-key",
      widget_name: "api-keys"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    organizations = Accounts.list_user_workos_organizations(socket.assigns.current_scope)
    selected_organization_id = default_organization_id(organizations)

    socket =
      socket
      |> assign(:page_title, "Settings")
      |> assign(:organizations, organizations)
      |> assign(:organization_options, organization_options(organizations))
      |> assign(:selected_organization_id, selected_organization_id)
      |> assign(:workos_user_id, socket.assigns.current_scope.user.workos_user_id)
      |> assign(:widget_token, nil)
      |> assign(:widget_error, nil)
      |> assign(:tabs, @tabs)
      |> assign(:active_tab, "profile")
      |> assign_organization_form(selected_organization_id)
      |> assign_widget_token()

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
      |> assign_organization_form(selected_organization_id)
      |> assign_widget_token()

    {:noreply, socket}
  end

  def handle_event("refresh_widget_token", _params, socket) do
    {:noreply, assign_widget_token(socket)}
  end

  def handle_event("switch_tab", %{"tab" => tab_id}, socket) do
    if Enum.any?(@tabs, &(&1.id == tab_id)) do
      {:noreply, assign(socket, :active_tab, tab_id)}
    else
      {:noreply, socket}
    end
  end

  defp assign_widget_token(
         %{assigns: %{selected_organization_id: nil, organization_options: []}} = socket
       ) do
    socket
    |> assign(:widget_token, nil)
    |> assign(:widget_error, nil)
  end

  defp assign_widget_token(%{assigns: %{selected_organization_id: nil}} = socket) do
    socket
    |> assign(:widget_token, nil)
    |> assign(:widget_error, :missing_workos_organization_id)
  end

  defp assign_widget_token(socket) do
    case Accounts.generate_user_management_widget_token(
           socket.assigns.current_scope,
           socket.assigns.selected_organization_id
         ) do
      {:ok, widget_token} ->
        socket
        |> assign(:widget_token, widget_token)
        |> assign(:widget_error, nil)

      {:error, reason} ->
        socket
        |> assign(:widget_token, nil)
        |> assign(:widget_error, reason)
    end
  end

  defp assign_organization_form(socket, selected_organization_id) do
    form =
      to_form(
        %{"organization_id" => selected_organization_id || ""},
        as: :organization
      )

    assign(socket, :org_form, form)
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

  defp active_tab_config(tabs, active_tab) do
    Enum.find(tabs, List.first(tabs), &(&1.id == active_tab))
  end

  defp widget_error_message(:missing_workos_organization_id) do
    "No WorkOS organization is linked to this account yet."
  end

  defp widget_error_message(:missing_workos_user_id) do
    "This account is missing a WorkOS user id."
  end

  defp widget_error_message(:workos_not_configured) do
    "WorkOS is not configured for this environment."
  end

  defp widget_error_message(:forbidden) do
    "Your account does not have access to this organization."
  end

  defp widget_error_message(_reason) do
    "Could not initialize WorkOS user management widgets right now."
  end
end
