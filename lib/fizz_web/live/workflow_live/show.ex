defmodule FizzWeb.WorkflowLive.Show do
  @moduledoc """
  LiveView for showing workflow details and execution history.
  """
  use FizzWeb, :live_view

  alias Fizz.Workflows
  alias Fizz.Executions
  alias Fizz.Executions.Execution
  import FizzWeb.Formatters

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Workflows.get_workflow(id, scope) do
      {:ok, workflow} ->
        executions = Executions.list_workflow_executions(scope, workflow, limit: 10)

        socket =
          socket
          |> assign(:page_title, workflow.name)
          |> assign(:workflow, workflow)
          |> assign(:executions, executions)

        {:ok, socket}

      {:error, :not_found} ->
        socket =
          socket
          |> put_flash(:error, "Workflow not found")
          |> redirect(to: ~p"/workflows")

        {:ok, socket}
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
                <.link navigate={~p"/workflows"} class="btn btn-ghost btn-sm">
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
              <div class="flex items-center gap-3">
                <.link
                  navigate={~p"/workflows/#{@workflow.id}/edit"}
                  class="btn btn-primary gap-2"
                >
                  <.icon name="hero-play" class="size-4" />
                  <span>Run Workflow</span>
                </.link>
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
        <%!-- Recent Executions Section --%>
        <section>
          <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 p-6">
            <h2 class="text-lg font-semibold text-base-content mb-4 flex items-center gap-2">
              <.icon name="hero-clock" class="size-5" /> Recent Executions
            </h2>

            <%= if Enum.empty?(@executions) do %>
              <div class="text-center py-8 text-base-content/60">
                <.icon name="hero-inbox" class="size-8 mx-auto mb-2" />
                <p class="text-sm">No executions yet</p>
                <p class="text-xs mt-1">Run the workflow to see results here</p>
              </div>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>ID</th>
                      <th>Status</th>
                      <th>Input</th>
                      <th>Output</th>
                      <th>Duration</th>
                      <th>Started</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for execution <- @executions do %>
                      <tr class="hover">
                        <td class="font-mono text-xs">
                          <div class="flex items-center gap-2">
                            {short_id(execution.id)}
                            <span
                              :if={partial_execution?(execution)}
                              title="Partial execution"
                              class="inline-flex items-center"
                            >
                              <.icon name="hero-beaker" class="size-4 text-primary/80" />
                            </span>
                          </div>
                        </td>
                        <td>
                          <span class={["badge badge-xs", execution_status_class(execution.status)]}>
                            {execution.status}
                          </span>
                        </td>
                        <td class="max-w-32 truncate text-xs">
                          {format_execution_value(execution.trigger && execution.trigger.data)}
                        </td>
                        <td class="max-w-48 truncate text-xs">
                          {format_execution_value(execution.output)}
                        </td>
                        <td class="text-xs">
                          {format_duration(Execution.duration_us(execution))}
                        </td>
                        <td class="text-xs text-base-content/60">
                          {format_relative_time(execution.started_at)}
                        </td>
                        <td>
                          <.link
                            navigate={~p"/workflows/#{@workflow.id}/execution/#{execution.id}"}
                            class="btn btn-ghost btn-xs"
                            title="Inspect execution"
                          >
                            <.icon name="hero-eye" class="size-4" />
                          </.link>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </section>

        <%!-- Workflow Details Section --%>
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

  # Helper functions

  defp partial_execution?(%{metadata: %{extras: extras}}) when is_map(extras) do
    Map.get(extras, "partial") || Map.get(extras, :partial) || false
  end

  defp partial_execution?(_), do: false

  defp format_execution_value(nil), do: "-"

  defp format_execution_value(%{"value" => value}), do: inspect(value)
  defp format_execution_value(%{"productions" => prods}) when is_list(prods), do: inspect(prods)
  defp format_execution_value(value) when is_map(value), do: inspect(value)
  defp format_execution_value(value), do: inspect(value)
end
