defmodule FizzWeb.IntegrationsLive do
  use FizzWeb, :live_view

  alias Fizz.Accounts

  @default_widget_scopes ["widgets:pipes:manage", "widgets:api_keys:manage"]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Integrations")
      |> assign(:widget_token, nil)
      |> assign(:widget_token_error, nil)
      |> assign(:connection_statuses, default_connection_statuses())
      |> assign(:credentials, [])
      |> assign(:provider_options, provider_options())
      |> assign_form()
      |> load_credentials()

    socket =
      if connected?(socket) do
        load_connections(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh_connections", _params, socket) do
    {:noreply, load_connections(socket)}
  end

  def handle_event("issue_widget_token", _params, socket) do
    case Accounts.generate_workos_widget_token(
           socket.assigns.current_scope,
           @default_widget_scopes
         ) do
      {:ok, token} ->
        {:noreply, assign(socket, widget_token: token, widget_token_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, widget_token_error: inspect(reason), widget_token: nil)}
    end
  end

  def handle_event("validate_credential", %{"credential" => params}, socket) do
    changeset =
      params
      |> Accounts.change_byo_credential()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, credential_form: to_form(changeset, as: :credential))}
  end

  def handle_event("create_credential", %{"credential" => params}, socket) do
    case Accounts.create_byo_credential(socket.assigns.current_scope, params) do
      {:ok, _credential} ->
        {:noreply,
         socket
         |> put_flash(:info, "Credential stored in WorkOS Vault.")
         |> assign_form()
         |> load_credentials()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           credential_form: to_form(Map.put(changeset, :action, :insert), as: :credential)
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save credential: #{inspect(reason)}")}
    end
  end

  def handle_event("revoke_credential", %{"id" => id}, socket) do
    case Accounts.revoke_byo_credential(socket.assigns.current_scope, id) do
      {:ok, _credential} ->
        {:noreply, socket |> put_flash(:info, "Credential revoked.") |> load_credentials()}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Credential was not found.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not revoke credential: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section id="integration-settings" class="space-y-8">
        <div class="relative overflow-hidden rounded-box border border-base-300 bg-base-100 px-6 py-8 shadow-sm">
          <div class="pointer-events-none absolute inset-0 bg-[radial-gradient(1200px_circle_at_100%_-10%,color-mix(in_oklab,var(--color-primary)_18%,transparent),transparent_48%)]" />
          <div class="relative flex flex-wrap items-center justify-between gap-4">
            <div class="space-y-2">
              <h1 class="text-2xl font-semibold tracking-tight">Integration Hub</h1>
              <p class="max-w-xl text-sm text-base-content/70">
                Manage connected apps through WorkOS Pipes and store bring-your-own credentials in WorkOS Vault.
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-2">
              <.button id="connections-refresh-button" phx-click="refresh_connections">
                <.icon name="hero-arrow-path" class="size-4 transition-transform hover:rotate-180" />
                Refresh Apps
              </.button>
              <.button id="issue-widget-token-button" phx-click="issue_widget_token" variant="primary">
                <.icon name="hero-key" class="size-4" /> Issue Widget Token
              </.button>
            </div>
          </div>
          <div
            :if={@widget_token_error}
            id="widget-token-error"
            class="relative mt-4 rounded-box border border-error/40 bg-error/10 px-3 py-2 text-sm text-error"
          >
            {@widget_token_error}
          </div>
          <div :if={@widget_token} class="relative mt-4 space-y-2">
            <label
              for="widget-token"
              class="text-xs font-semibold uppercase tracking-wide text-base-content/60"
            >
              Widget Token
            </label>
            <textarea
              id="widget-token"
              class="textarea h-24 w-full font-mono text-xs"
              readonly
            ><%= @widget_token %></textarea>
          </div>
        </div>

        <div id="connected-apps-section" class="space-y-4">
          <div class="flex items-center justify-between">
            <h2 class="text-lg font-semibold tracking-tight">Connected Apps</h2>
            <p class="text-xs uppercase tracking-wide text-base-content/60">
              WorkOS Pipes
            </p>
          </div>

          <div class="grid gap-4 md:grid-cols-2">
            <%= for provider <- @connection_statuses do %>
              <article
                id={"provider-#{provider.slug}"}
                class="group rounded-box border border-base-300 bg-base-100 p-4 shadow-sm transition duration-200 hover:-translate-y-0.5 hover:border-base-content/20"
              >
                <div class="flex items-start justify-between gap-4">
                  <div class="space-y-1">
                    <p class="text-xs uppercase tracking-wide text-base-content/50">
                      {provider.category}
                    </p>
                    <h3 class="text-base font-semibold">{provider.name}</h3>
                    <p class="text-sm text-base-content/70">{provider.description}</p>
                  </div>
                  <.icon
                    name={provider_icon(provider.slug)}
                    class="size-6 text-base-content/50 transition group-hover:scale-110"
                  />
                </div>
                <div class="mt-4 flex items-center justify-between gap-2">
                  <span class={["badge badge-sm border-none", status_badge_class(provider.status)]}>
                    {status_label(provider.status)}
                  </span>
                  <span class="text-xs text-base-content/60">{provider.message}</span>
                </div>
                <div :if={provider.missing_scopes != []} class="mt-3 text-xs text-warning">
                  Missing scopes: {Enum.join(provider.missing_scopes, ", ")}
                </div>
              </article>
            <% end %>
          </div>
        </div>

        <div id="byo-credentials-section" class="space-y-4">
          <div class="flex items-center justify-between">
            <h2 class="text-lg font-semibold tracking-tight">BYO Credentials</h2>
            <p class="text-xs uppercase tracking-wide text-base-content/60">
              WorkOS Vault
            </p>
          </div>

          <div class="grid gap-4 lg:grid-cols-[minmax(0,20rem)_1fr]">
            <div class="rounded-box border border-base-300 bg-base-100 p-4 shadow-sm">
              <.form
                for={@credential_form}
                id="byo-credential-form"
                phx-change="validate_credential"
                phx-submit="create_credential"
              >
                <.input
                  field={@credential_form[:provider]}
                  type="select"
                  options={@provider_options}
                  prompt="Select provider"
                  label="Provider"
                />
                <.input field={@credential_form[:label]} type="text" label="Credential label" />
                <.input
                  field={@credential_form[:secret]}
                  type="password"
                  label="Secret / API key"
                  autocomplete="off"
                />
                <.button
                  id="save-byo-credential-button"
                  type="submit"
                  class="btn btn-primary btn-block mt-2"
                >
                  Save Credential
                </.button>
              </.form>
            </div>

            <div class="rounded-box border border-base-300 bg-base-100 p-4 shadow-sm">
              <.table id="byo-credentials-table" rows={@credentials}>
                <:col :let={credential} label="Provider">
                  <span class="font-medium">{credential.provider}</span>
                </:col>
                <:col :let={credential} label="Label">{credential.label}</:col>
                <:col :let={credential} label="Status">
                  <span class={["badge badge-sm border-none", status_badge_class(credential.status)]}>
                    {status_label(credential.status)}
                  </span>
                </:col>
                <:col :let={credential} label="Saved">
                  <time>{Calendar.strftime(credential.inserted_at, "%Y-%m-%d %H:%M UTC")}</time>
                </:col>
                <:action :let={credential}>
                  <.button
                    id={"revoke-credential-#{credential.id}"}
                    class="btn btn-xs btn-soft btn-error"
                    phx-click="revoke_credential"
                    phx-value-id={credential.id}
                    disabled={credential.status == :revoked}
                  >
                    Revoke
                  </.button>
                </:action>
              </.table>
              <p
                :if={@credentials == []}
                id="empty-byo-credentials"
                class="mt-4 text-sm text-base-content/60"
              >
                No credentials stored yet.
              </p>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp assign_form(socket, attrs \\ %{}) do
    changeset = Accounts.change_byo_credential(attrs)
    assign(socket, :credential_form, to_form(changeset, as: :credential))
  end

  defp load_connections(socket) do
    case Accounts.list_connected_app_statuses(socket.assigns.current_scope) do
      {:ok, statuses} ->
        assign(socket, :connection_statuses, statuses)

      {:error, reason} ->
        assign(socket, :connection_statuses, unavailable_connection_statuses(reason))
    end
  end

  defp load_credentials(socket) do
    assign(socket, :credentials, Accounts.list_byo_credentials(socket.assigns.current_scope))
  end

  defp provider_options do
    Accounts.supported_integration_providers()
    |> Enum.map(fn provider -> {provider.name, provider.slug} end)
  end

  defp unavailable_connection_statuses(reason) do
    Accounts.supported_integration_providers()
    |> Enum.map(fn provider ->
      %{
        slug: provider.slug,
        name: provider.name,
        category: provider.category,
        description: provider.description,
        connected?: false,
        status: :unavailable,
        message: "Status unavailable: #{inspect(reason)}",
        granted_scopes: [],
        missing_scopes: []
      }
    end)
  end

  defp default_connection_statuses do
    Accounts.supported_integration_providers()
    |> Enum.map(fn provider ->
      %{
        slug: provider.slug,
        name: provider.name,
        category: provider.category,
        description: provider.description,
        connected?: false,
        status: :unavailable,
        message: "Status will load after connection is established.",
        granted_scopes: [],
        missing_scopes: []
      }
    end)
  end

  defp provider_icon("github"), do: "hero-code-bracket-square"
  defp provider_icon("google_drive"), do: "hero-folder"
  defp provider_icon("slack"), do: "hero-chat-bubble-left-right"
  defp provider_icon("microsoft_teams"), do: "hero-user-group"
  defp provider_icon(_provider), do: "hero-puzzle-piece"

  defp status_badge_class(:connected), do: "bg-success/15 text-success"
  defp status_badge_class(:active), do: "bg-success/15 text-success"
  defp status_badge_class(:needs_reauthorization), do: "bg-warning/20 text-warning"
  defp status_badge_class(:revoked), do: "bg-error/20 text-error"
  defp status_badge_class(_status), do: "bg-base-200 text-base-content/70"

  defp status_label(:connected), do: "Connected"
  defp status_label(:active), do: "Active"
  defp status_label(:needs_reauthorization), do: "Reconnect"
  defp status_label(:not_connected), do: "Not Connected"
  defp status_label(:revoked), do: "Revoked"
  defp status_label(:unavailable), do: "Unavailable"

  defp status_label(status),
    do: status |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
