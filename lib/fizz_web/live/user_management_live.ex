defmodule FizzWeb.UserManagementLive do
  use FizzWeb, :live_view

  alias Fizz.Accounts
  alias Fizz.Accounts.ExternalAuth, as: AccountExternalAuth
  alias Fizz.Fields.Credential
  alias Fizz.Integrations.Auth.ProviderCatalog

  @user_tabs [
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
      id: "sessions",
      title: "Sessions",
      icon: "hero-computer-desktop",
      widget_name: "user-sessions"
    }
  ]

  @org_tabs [
    %{
      id: "members",
      title: "Members",
      icon: "hero-user-group",
      widget_name: "users-management"
    },
    %{
      id: "connections",
      title: "Connections",
      icon: "hero-link",
      widget_name: "pipes"
    },
    %{
      id: "api-keys",
      title: "Credentials",
      icon: "hero-key",
      widget_name: "api-keys"
    }
  ]

  @all_tabs @user_tabs ++ @org_tabs

  @impl true
  def mount(_params, _session, socket) do
    organizations = Accounts.ensure_personal_organization(socket.assigns.current_scope)
    selected_organization_id = default_organization_id(organizations)
    provider_catalog = ProviderCatalog.api_key_providers()

    socket =
      socket
      |> assign(:page_title, "Settings")
      |> assign(:organizations, organizations)
      |> assign(:organization_options, organization_options(organizations))
      |> assign(:selected_organization_id, selected_organization_id)
      |> assign(:workos_user_id, socket.assigns.current_scope.user.workos_user_id)
      |> assign(:widget_token, nil)
      |> assign(:widget_error, nil)
      |> assign(:user_tabs, @user_tabs)
      |> assign(:org_tabs, @org_tabs)
      |> assign(:active_tab, "profile")
      |> assign(:show_create_org_modal, false)
      |> assign(:create_org_form, to_form(%{"name" => ""}, as: :create_org))
      |> assign(:provider_catalog, provider_catalog)
      |> assign(:provider_options, provider_options(provider_catalog))
      |> assign(:show_create_credential_modal, false)
      |> assign(:credential_modal_step, :select_provider)
      |> assign(:provider_search_query, "")
      |> assign(:filtered_providers, provider_catalog)
      |> assign(:selected_provider, nil)
      |> assign(:show_rotate_credential_modal, false)
      |> assign(:show_delete_credential_modal, false)
      |> assign(:selected_credential_id, nil)
      |> assign(:credentials_error, nil)
      |> assign(:credentials, [])
      |> assign(:credential_form, credential_form(provider_catalog))
      |> assign(:rotate_credential_form, rotate_credential_form())
      |> assign_organization_form(selected_organization_id)
      |> load_credentials()
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
      |> load_credentials()
      |> assign_widget_token()

    {:noreply, socket}
  end

  def handle_event("refresh_widget_token", _params, socket) do
    {:noreply, assign_widget_token(socket)}
  end

  def handle_event("switch_tab", %{"tab" => tab_id}, socket) do
    if Enum.any?(@all_tabs, &(&1.id == tab_id)) do
      {:noreply, assign(socket, :active_tab, tab_id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_create_credential_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_credential_modal, true)
     |> assign(:credential_modal_step, :select_provider)
     |> assign(:provider_search_query, "")
     |> assign(:filtered_providers, socket.assigns.provider_catalog)
     |> assign(:selected_provider, nil)
     |> assign(:credential_form, credential_form(socket.assigns.provider_catalog))}
  end

  def handle_event("close_create_credential_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_credential_modal, false)
     |> assign(:credential_modal_step, :select_provider)
     |> assign(:provider_search_query, "")
     |> assign(:filtered_providers, socket.assigns.provider_catalog)
     |> assign(:selected_provider, nil)
     |> assign(:credential_form, credential_form(socket.assigns.provider_catalog))}
  end

  def handle_event("search_providers", %{"query" => query}, socket) do
    filtered =
      filter_providers(socket.assigns.provider_catalog, query)

    {:noreply,
     socket
     |> assign(:provider_search_query, query)
     |> assign(:filtered_providers, filtered)}
  end

  def handle_event("select_provider", %{"provider_id" => provider_id}, socket) do
    catalog = socket.assigns.provider_catalog
    provider = Enum.find(catalog, &(&1.id == provider_id))

    if provider do
      form_params = %{
        "provider" => provider.id,
        "provider_label" => provider.label,
        "provider_custom_name" => "",
        "credentials" => Credential.defaults(provider.id)
      }

      {:noreply,
       socket
       |> assign(:credential_modal_step, :configure)
       |> assign(:selected_provider, provider)
       |> assign(:credential_form, credential_form(catalog, form_params))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("credential_modal_back", _params, socket) do
    {:noreply,
     socket
     |> assign(:credential_modal_step, :select_provider)
     |> assign(:selected_provider, nil)
     |> assign(:provider_search_query, "")
     |> assign(:filtered_providers, socket.assigns.provider_catalog)}
  end

  def handle_event("validate_credential", %{"credential" => params}, socket) do
    {:noreply,
     assign(socket, :credential_form, credential_form(socket.assigns.provider_catalog, params))}
  end

  def handle_event("create_credential", %{"credential" => params}, socket) do
    organization_id = socket.assigns.selected_organization_id

    if is_binary(organization_id) and byte_size(organization_id) > 0 do
      attrs = normalize_credential_params(params, socket.assigns.provider_catalog)

      case AccountExternalAuth.create_credential(
             socket.assigns.current_scope,
             organization_id,
             attrs
           ) do
        {:ok, _credential} ->
          {:noreply,
           socket
           |> assign(:show_create_credential_modal, false)
           |> assign(:credential_modal_step, :select_provider)
           |> assign(:selected_provider, nil)
           |> assign(:credential_form, credential_form(socket.assigns.provider_catalog))
           |> load_credentials()
           |> put_flash(:info, "Credential created.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :credential_form, to_form(changeset, as: :credential))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, credential_error_message(reason))}
      end
    else
      {:noreply, put_flash(socket, :error, "Select an organization before creating credentials.")}
    end
  end

  def handle_event("open_rotate_credential_modal", %{"credential_id" => credential_id}, socket) do
    case Enum.find(socket.assigns.credentials, &(&1.id == credential_id)) do
      nil ->
        {:noreply, socket}

      credential ->
        {:noreply,
         socket
         |> assign(:selected_credential_id, credential.id)
         |> assign(:show_rotate_credential_modal, true)
         |> assign(:rotate_credential_form, rotate_credential_form(credential))}
    end
  end

  def handle_event("close_rotate_credential_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_rotate_credential_modal, false)
     |> assign(:selected_credential_id, nil)
     |> assign(:rotate_credential_form, rotate_credential_form())}
  end

  def handle_event("validate_rotate_credential", %{"rotate_credential" => params}, socket) do
    {:noreply, assign(socket, :rotate_credential_form, to_form(params, as: :rotate_credential))}
  end

  def handle_event("rotate_credential", %{"rotate_credential" => params}, socket) do
    organization_id = socket.assigns.selected_organization_id
    credential_id = socket.assigns.selected_credential_id

    if is_binary(organization_id) and is_binary(credential_id) do
      attrs = normalize_rotate_credential_params(params)

      case AccountExternalAuth.rotate_credential(
             socket.assigns.current_scope,
             organization_id,
             credential_id,
             attrs
           ) do
        {:ok, _credential} ->
          {:noreply,
           socket
           |> assign(:show_rotate_credential_modal, false)
           |> assign(:selected_credential_id, nil)
           |> assign(:rotate_credential_form, rotate_credential_form())
           |> load_credentials()
           |> put_flash(:info, "Credential rotated.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           assign(socket, :rotate_credential_form, to_form(changeset, as: :rotate_credential))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, credential_error_message(reason))}
      end
    else
      {:noreply, put_flash(socket, :error, "Select a credential before rotating.")}
    end
  end

  def handle_event("open_delete_credential_modal", %{"credential_id" => credential_id}, socket) do
    if Enum.any?(socket.assigns.credentials, &(&1.id == credential_id)) do
      {:noreply,
       socket
       |> assign(:selected_credential_id, credential_id)
       |> assign(:show_delete_credential_modal, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_delete_credential_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_credential_modal, false)
     |> assign(:selected_credential_id, nil)}
  end

  def handle_event("delete_credential", _params, socket) do
    organization_id = socket.assigns.selected_organization_id
    credential_id = socket.assigns.selected_credential_id

    if is_binary(organization_id) and is_binary(credential_id) do
      case AccountExternalAuth.delete_credential(
             socket.assigns.current_scope,
             organization_id,
             credential_id
           ) do
        {:ok, _credential} ->
          {:noreply,
           socket
           |> assign(:show_delete_credential_modal, false)
           |> assign(:selected_credential_id, nil)
           |> load_credentials()
           |> put_flash(:info, "Credential deleted.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, credential_error_message(reason))}
      end
    else
      {:noreply, put_flash(socket, :error, "Select a credential before deleting.")}
    end
  end

  def handle_event("open_create_org_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_create_org_modal, true)
      |> assign(:create_org_form, to_form(%{"name" => ""}, as: :create_org))

    {:noreply, socket}
  end

  def handle_event("close_create_org_modal", _params, socket) do
    {:noreply, assign(socket, :show_create_org_modal, false)}
  end

  def handle_event("validate_create_org", %{"create_org" => params}, socket) do
    {:noreply, assign(socket, :create_org_form, to_form(params, as: :create_org))}
  end

  def handle_event("create_organization", %{"create_org" => %{"name" => name}}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, socket}
    else
      case Accounts.create_organization(socket.assigns.current_scope, %{name: name}) do
        {:ok, org} ->
          organizations =
            Accounts.ensure_personal_organization(socket.assigns.current_scope)

          socket =
            socket
            |> assign(:organizations, organizations)
            |> assign(:organization_options, organization_options(organizations))
            |> assign(:selected_organization_id, org.organization_id)
            |> assign(:show_create_org_modal, false)
            |> assign_organization_form(org.organization_id)
            |> assign_widget_token()

          {:noreply, socket}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not create organization.")}
      end
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
    case Accounts.generate_widget_token(
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

  defp load_credentials(%{assigns: %{selected_organization_id: nil}} = socket) do
    socket
    |> assign(:credentials, [])
    |> assign(:credentials_error, nil)
  end

  defp load_credentials(socket) do
    case AccountExternalAuth.list_credentials(
           socket.assigns.current_scope,
           socket.assigns.selected_organization_id
         ) do
      {:ok, credentials} ->
        socket
        |> assign(:credentials, credentials)
        |> assign(:credentials_error, nil)

      {:error, reason} ->
        socket
        |> assign(:credentials, [])
        |> assign(:credentials_error, reason)
    end
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

  defp credential_form(provider_catalog, params \\ %{}) do
    provider = Map.get(params, "provider") || default_provider(provider_catalog)

    provider_label =
      Map.get(params, "provider_label") || provider_label_for(provider_catalog, provider)

    defaults = %{
      "provider" => provider,
      "provider_label" => provider_label,
      "provider_custom_name" => Map.get(params, "provider_custom_name", ""),
      "credentials" => Credential.defaults(provider)
    }

    to_form(merge_credential_form_params(defaults, params), as: :credential)
  end

  defp rotate_credential_form(credential \\ nil)

  defp rotate_credential_form(nil) do
    to_form(
      %{
        "provider_label" => "",
        "provider_custom_name" => "",
        "provider" => "",
        "credentials" => %{}
      },
      as: :rotate_credential
    )
  end

  defp rotate_credential_form(credential) do
    to_form(
      %{
        "provider_label" => credential.provider_label || "",
        "provider_custom_name" => credential.provider_custom_name || "",
        "provider" => credential.provider || "",
        "credentials" => Credential.defaults(credential.provider)
      },
      as: :rotate_credential
    )
  end

  defp normalize_credential_params(params, provider_catalog) do
    provider = Map.get(params, "provider") || default_provider(provider_catalog)

    provider_label =
      Map.get(params, "provider_label") || provider_label_for(provider_catalog, provider)

    %{
      provider: provider,
      provider_label: provider_label,
      provider_custom_name: Map.get(params, "provider_custom_name"),
      credentials: Map.get(params, "credentials", %{})
    }
  end

  defp normalize_rotate_credential_params(params) do
    %{
      provider_label: Map.get(params, "provider_label"),
      provider_custom_name: Map.get(params, "provider_custom_name"),
      credentials: Map.get(params, "credentials", %{})
    }
  end

  defp merge_credential_form_params(defaults, params) do
    defaults
    |> Map.merge(params)
    |> Map.put(
      "credentials",
      Map.merge(Map.get(defaults, "credentials", %{}), Map.get(params, "credentials", %{}))
    )
  end

  defp default_provider(provider_catalog) do
    provider_catalog
    |> Enum.find(&(!&1.custom))
    |> case do
      nil -> "custom_api_key"
      provider -> provider.id
    end
  end

  defp provider_label_for(provider_catalog, provider_id) do
    provider_catalog
    |> Enum.find(&(&1.id == provider_id))
    |> case do
      nil -> provider_id
      provider -> provider.label
    end
  end

  defp provider_options(provider_catalog) do
    Enum.map(provider_catalog, fn provider ->
      {provider.label, provider.id}
    end)
  end

  defp filter_providers(catalog, query) do
    query = String.trim(query) |> String.downcase()

    if query == "" do
      catalog
    else
      Enum.filter(catalog, fn provider ->
        String.contains?(String.downcase(provider.label), query) ||
          String.contains?(String.downcase(provider.id), query)
      end)
    end
  end

  defp provider_logo_path(provider_catalog, provider_id) do
    provider_catalog
    |> Enum.find(&(&1.id == provider_id))
    |> case do
      nil -> nil
      provider -> provider.logo_path
    end
  end

  defp credential_fields(provider_id) when is_binary(provider_id),
    do: Credential.fields(provider_id)

  defp credential_fields(_provider_id), do: []

  defp credential_fields_for(%{provider: provider}), do: credential_fields(provider)
  defp credential_fields_for(_credential), do: []

  defp credential_field_name(form, field) do
    "#{form.name}[credentials][#{field.key}]"
  end

  defp credential_field_id(form, field) do
    "#{form.id}_credentials_#{field.key}"
  end

  defp credential_field_value(form, field) do
    form
    |> credential_form_values()
    |> Map.get(field.key, "")
  end

  defp credential_form_values(form) do
    case credential_values_from_form_source(form.params) ||
           credential_values_from_form_source(form.source) do
      values when is_map(values) -> values
      _values -> %{}
    end
  end

  defp credential_values_from_form_source(%Ecto.Changeset{}), do: nil

  defp credential_values_from_form_source(source) when is_map(source) do
    case Map.get(source, "credentials") || Map.get(source, :credentials) do
      values when is_map(values) -> values
      _values -> nil
    end
  end

  defp credential_values_from_form_source(_source), do: nil

  defp credential_error_message(:organization_load_failed),
    do: "Could not load organization credentials right now."

  defp credential_error_message(:credential_not_found), do: "Credential not found."
  defp credential_error_message(:missing_secret_value), do: "Secret value is required."
  defp credential_error_message(:invalid_provider), do: "Select a valid provider."
  defp credential_error_message(:invalid_provider_label), do: "Provider label is required."

  defp credential_error_message(:missing_custom_provider_name),
    do: "Custom provider name is required."

  defp credential_error_message(:vault_secret_not_found),
    do: "Could not read secret value from vault."

  defp credential_error_message(:invalid_vault_object_response),
    do: "Vault returned an invalid response."

  defp credential_error_message({:workos_http_error, 429, _message}),
    do: "Vault is currently rate-limited. Please retry in a moment."

  defp credential_error_message(_reason),
    do: "Could not complete the credential action right now."
end
