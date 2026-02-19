defmodule FizzWeb.WorkflowLive.Index do
  @moduledoc """
  LiveView for browsing workflows.

  Presents an index of workflows with ability to create new ones.
  """
  use FizzWeb, :live_view

  alias Fizz.Workflows
  import FizzWeb.Formatters

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    workflows =
      scope
      |> Workflows.list_workflows()
      |> sort_workflows()

    {:ok,
     socket
     |> assign(workflows_empty?: workflows == [])
     |> stream(:workflows, workflows)}
  end

  @impl true
  def handle_event("open_workflow", %{"workflow_id" => workflow_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/workflows/#{workflow_id}")}
  end

  @impl true
  def handle_event("duplicate_workflow", %{"workflow_id" => workflow_id}, socket) do
    scope = socket.assigns.current_scope

    case Workflows.get_workflow(scope, workflow_id) do
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Workflow not found")}

      {:ok, workflow} ->
        case Workflows.duplicate_workflow(scope, workflow) do
          {:ok, duplicated_workflow} ->
            socket =
              socket
              |> put_flash(:info, "Workflow duplicated successfully")
              |> stream_insert(:workflows, duplicated_workflow, at: 0)

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to duplicate workflow")}
        end
    end
  end

  @impl true
  def handle_event("archive_workflow", %{"workflow_id" => workflow_id}, socket) do
    scope = socket.assigns.current_scope

    case Workflows.get_workflow(scope, workflow_id) do
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Workflow not found")}

      {:ok, workflow} ->
        case Workflows.archive_workflow(scope, workflow) do
          {:ok, archived_workflow} ->
            socket =
              socket
              |> put_flash(:info, "Workflow archived successfully")
              |> stream_insert(:workflows, archived_workflow)

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to archive workflow")}
        end
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
              <p class="text-xs font-semibold uppercase tracking-[0.3em] text-muted">Automation</p>
              <div class="flex flex-wrap items-center gap-3">
                <h1 class="text-3xl font-semibold tracking-tight text-base-content">Workflows</h1>
              </div>
              <p class="max-w-2xl text-sm text-muted">
                Design, publish, and monitor the automations.
                Drafts stay private until you publish them.
              </p>
            </div>

            <div class="flex gap-3">
              <button
                type="button"
                phx-click={show_modal("test-modal")}
                class="btn btn-sm btn-outline gap-2"
              >
                <.icon name="hero-beaker" class="size-5" />
                <span>Test Modal</span>
              </button>

              <button
                type="button"
                phx-click="open_create_modal"
                class="btn btn-sm btn-primary gap-2 "
              >
                <.icon name="hero-plus" class="size-5" />
                <span>New Workflow</span>
              </button>
            </div>
          </div>
        </div>
      </:page_header>

      <div class="space-y-8">
        <section>
          <div class="card relative overflow-hidden transition-all duration-300 border border-base-300 rounded-2xl shadow-sm ring-1 ring-base-300/70 bg-base-100 p-3">
            <div class="flex items-center justify-between px-4 text-sm"></div>
            <.data_table
              id="workflows"
              rows={@streams.workflows}
              rows_empty?={@workflows_empty?}
              tbody_class="divide-y divide-base-200"
              row_click={&navigate_to_workflow/1}
              row_class="cursor-pointer hover:bg-neutral/10"
            >
              <:col :let={workflow} label="Workflow">
                <div class="space-y-2">
                  <div class="flex flex-wrap items-center gap-2">
                    <p class="text-sm font-semibold text-base-content">{workflow.name}</p>
                    <span :if={workflow.current_version_tag} class="badge badge-ghost badge-xs">
                      v{workflow.current_version_tag}
                    </span>
                  </div>
                  <p class="text-xs leading-relaxed text-base-content/70">
                    {workflow.description}
                  </p>
                  <p class="text-[11px] font-mono uppercase tracking-wide text-base-content/50">
                    {short_id(workflow.id)}
                  </p>
                </div>
              </:col>

              <:col :let={workflow} label="Trigger" width="12%">
                <div class="flex items-center gap-2 text-xs font-medium text-base-content/80">
                  <.icon name="hero-bolt" class="size-4 opacity-70" />
                  <span>{trigger_label(workflow)}</span>
                </div>
              </:col>

              <:col :let={workflow} label="Status" width="10%" align="center">
                <span
                  class={["badge badge-sm", status_badge_class(workflow.status)]}
                  data-role="status"
                  data-status={workflow.status}
                >
                  {status_label(workflow.status)}
                </span>
              </:col>

              <:col :let={workflow} label="Owner" width="14%">
                <div class="flex items-center gap-2 text-xs text-base-content/80">
                  <.icon name="hero-user" class="size-4 opacity-70" />
                  <span>{owner_name(workflow)}</span>
                </div>
              </:col>

              <:col :let={workflow} label="Access" width="10%" align="center">
                <span class={["badge badge-xs", elem(access_state_badge(workflow, @current_scope), 1)]}>
                  {elem(access_state_badge(workflow, @current_scope), 0)}
                </span>
              </:col>

              <:col :let={workflow} label="Updated" width="14%">
                <div class="flex items-center gap-2 text-xs text-base-content/70">
                  <.icon name="hero-clock" class="size-4 opacity-70" />
                  <span>{formatted_timestamp(workflow.updated_at)}</span>
                </div>
              </:col>

              <:col :let={workflow} label="Created" width="14%">
                <div class="text-xs text-base-content/60">
                  {formatted_timestamp(workflow.inserted_at)}
                </div>
              </:col>

              <:col :let={workflow} label="Actions" width="10%" align="center">
                <div class="relative">
                  <button
                    type="button"
                    class="btn btn-ghost btn-sm btn-circle"
                    popovertarget={"workflow-actions-#{workflow.id}"}
                    style={"anchor-name:--workflow-actions-#{workflow.id}"}
                    @click.stop
                  >
                    <.icon name="hero-ellipsis-horizontal" class="size-4" />
                  </button>
                  <ul
                    class="dropdown menu w-52 rounded-box bg-base-100 shadow-sm"
                    popover
                    id={"workflow-actions-#{workflow.id}"}
                    style={"position-anchor:--workflow-actions-#{workflow.id}"}
                  >
                    <li>
                      <button
                        type="button"
                        phx-click="open_workflow"
                        phx-value-workflow_id={workflow.id}
                        class="flex items-center gap-2"
                      >
                        <.icon name="hero-eye" class="size-4" />
                        <span>Open</span>
                      </button>
                    </li>
                    <li>
                      <button
                        type="button"
                        phx-click="duplicate_workflow"
                        phx-value-workflow_id={workflow.id}
                        class="flex items-center gap-2"
                      >
                        <.icon name="hero-document-duplicate" class="size-4" />
                        <span>Duplicate</span>
                      </button>
                    </li>
                    <li>
                      <button
                        type="button"
                        phx-click="archive_workflow"
                        phx-value-workflow_id={workflow.id}
                        class="flex items-center gap-2 text-error"
                      >
                        <.icon name="hero-archive-box" class="size-4" />
                        <span>Archive</span>
                      </button>
                    </li>
                  </ul>
                </div>
              </:col>

              <:empty_state>
                <div class="flex flex-col items-center justify-center gap-3 py-10 text-base-content/70">
                  <div class="rounded-full bg-base-200 p-3">
                    <.icon name="hero-rocket-launch" class="size-6" />
                  </div>
                  <div class="space-y-1 text-center">
                    <p class="text-sm font-semibold text-base-content">No workflows yet</p>
                    <p class="text-xs">Create one above to get started.</p>
                  </div>
                </div>
              </:empty_state>
            </.data_table>
          </div>
        </section>
      </div>

      <.modal id="test-modal">
        <div class="space-y-4">
          <h2 class="text-xl font-bold">Test Modal</h2>
          <p>This is a test modal component using DaisyUI.</p>
          <div class="flex justify-end">
            <button
              type="button"
              phx-click={hide_modal("test-modal")}
              class="btn btn-primary"
            >
              Close
            </button>
          </div>
        </div>
      </.modal>
    </Layouts.app>
    """
  end

  defp sort_workflows(workflows) do
    Enum.sort_by(
      workflows,
      fn workflow ->
        workflow.updated_at || workflow.inserted_at
      end,
      {:desc, DateTime}
    )
  end

  defp navigate_to_workflow({_, workflow}), do: JS.navigate(~p"/workflows/#{workflow.id}")
  defp navigate_to_workflow(workflow), do: JS.navigate(~p"/workflows/#{workflow.id}")

  # ============================================================================
  # Display Helpers
  # ============================================================================

  defp owner_name(workflow) do
    case workflow.user do
      nil -> "Unknown"
      user -> user.email || "User #{String.slice(user.id, 0, 8)}"
    end
  end

  defp access_state_badge(workflow, scope) do
    state = Workflows.workflow_access_state(scope, workflow)

    case state do
      :owner ->
        {"Owner", "badge-primary"}

      :editor ->
        {"Editor", "badge-secondary"}

      :viewer ->
        {"Viewer", "badge-ghost"}

      :public ->
        {"Public", "badge-outline"}

      nil ->
        {"No Access", "badge-error"}
    end
  end
end
