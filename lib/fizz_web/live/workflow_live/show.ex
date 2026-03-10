defmodule FizzWeb.WorkflowLive.Show do
  @moduledoc """
  LiveView for showing workflow details and execution history.
  """
  use FizzWeb, :live_view

  alias Fizz.Accounts
  alias Fizz.Workflows
  alias FizzWeb.WorkflowLive.Paths
  import FizzWeb.Formatters

  @impl true
  def mount(%{"workspace_id" => workspace_id, "id" => id}, _session, socket) do
    with {:ok, scope} <-
           Accounts.build_scope_for_workspace(socket.assigns.current_scope, workspace_id),
         {:ok, workflow} <- Workflows.get_workflow(scope, id) do
      socket =
        socket
        |> assign(:current_scope, scope)
        |> assign(:page_title, workflow.name)
        |> assign(:workflow, workflow)

      {:ok, socket}
    else
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Workflow not found")
         |> redirect(to: ~p"/workspaces")}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Workspace not found")
         |> redirect(to: ~p"/workspaces")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <:page_header>
        <div class="w-full space-y-6">
          <div class="flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between">
            <div class="space-y-3">
              <div class="flex items-center gap-3">
                <.link
                  navigate={Paths.workflows_index_path(@current_scope)}
                  class="btn btn-ghost btn-sm"
                >
                  <.icon name="hero-arrow-left" class="size-4" />
                  <span>Back to Workflows</span>
                </.link>
              </div>
              <div class="flex flex-wrap items-center gap-3">
                <h1 class="text-3xl font-semibold tracking-tight text-base-content">
                  {@workflow.name}
                </h1>
                <span :if={@workflow.current_version_tag} class="badge badge-ghost badge-xs">
                  v{@workflow.current_version_tag}
                </span>
                <span class={["badge badge-sm", status_badge_class(@workflow.status)]}>
                  {status_label(@workflow.status)}
                </span>
              </div>
              <p class="max-w-2xl text-sm text-muted">
                {@workflow.description || "No description provided."}
              </p>
              <div class="flex items-center gap-4 text-xs text-base-content/60">
                <div class="flex items-center gap-1">
                  <.icon name="hero-clock" class="size-4" />
                  <span>Updated {formatted_timestamp(@workflow.updated_at)}</span>
                </div>
                <div class="text-[11px] font-mono uppercase tracking-wide">
                  {short_id(@workflow.id)}
                </div>
              </div>
            </div>
          </div>
        </div>
      </:page_header>

      <div class="space-y-8">
        <section>
          <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 p-6">
            <h2 class="text-lg font-semibold text-base-content mb-4 flex items-center gap-2">
              <.icon name="hero-information-circle" class="size-5" /> Workflow Details
            </h2>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div class="space-y-4">
                <div>
                  <label class="text-sm font-medium text-base-content/70">Trigger</label>
                  <div class="flex items-center gap-2 mt-1">
                    <.icon name="hero-bolt" class="size-4 opacity-70" />
                    <span class="text-sm">{trigger_label(@workflow)}</span>
                  </div>
                </div>

                <div>
                  <label class="text-sm font-medium text-base-content/70">Status</label>
                  <div class="mt-1">
                    <span class={["badge badge-sm", status_badge_class(@workflow.status)]}>
                      {status_label(@workflow.status)}
                    </span>
                  </div>
                </div>

                <div>
                  <label class="text-sm font-medium text-base-content/70">Version</label>
                  <div class="mt-1">
                    <span class="text-sm">{@workflow.current_version_tag || "Unversioned"}</span>
                  </div>
                </div>
              </div>

              <div class="space-y-4">
                <div>
                  <label class="text-sm font-medium text-base-content/70">Created</label>
                  <div class="mt-1">
                    <span class="text-sm text-base-content/60">
                      {formatted_timestamp(@workflow.inserted_at)}
                    </span>
                  </div>
                </div>

                <div>
                  <label class="text-sm font-medium text-base-content/70">Last Updated</label>
                  <div class="mt-1">
                    <span class="text-sm text-base-content/60">
                      {formatted_timestamp(@workflow.updated_at)}
                    </span>
                  </div>
                </div>

                <div>
                  <label class="text-sm font-medium text-base-content/70">Workflow ID</label>
                  <div class="mt-1">
                    <code class="text-xs bg-base-200 px-2 py-1 rounded">{@workflow.id}</code>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
