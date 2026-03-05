defmodule FizzWeb.ExecutionLive.Show do
  @moduledoc """
  LiveView for showing an execution.
  """
  use FizzWeb, :live_view

  alias Fizz.Accounts
  alias Fizz.Executions
  alias Fizz.Executions.{Execution, StepExecution}
  alias Fizz.Executions.PubSub, as: ExecutionPubSub
  alias FizzWeb.ExecutionLive.ShowPresenter
  alias FizzWeb.WorkflowLive.Paths
  import FizzWeb.Formatters

  @execution_lifecycle_events [
    :execution_started,
    :execution_updated,
    :execution_completed,
    :execution_cancelled,
    :execution_failed
  ]
  @step_lifecycle_events [
    :step_started,
    :step_completed,
    :step_failed,
    :step_skipped,
    :step_cancelled
  ]

  @impl true
  def mount(
        %{
          "workspace_id" => workspace_id,
          "workflow_id" => workflow_id,
          "execution_id" => execution_id
        },
        _session,
        socket
      ) do
    case Accounts.build_scope_for_workspace(socket.assigns.current_scope, workspace_id) do
      {:ok, scope} ->
        case Executions.get_execution_with_steps(scope, execution_id) do
          {:ok, execution} ->
            if execution.workflow_id == workflow_id do
              step_executions = sort_step_executions(execution.step_executions)
              item_stats = build_item_stats(step_executions)

              socket =
                socket
                |> assign(:current_scope, scope)
                |> assign(:page_title, "Execution #{short_id(execution.id)}")
                |> assign(:workflow, execution.workflow)
                |> assign(:execution, execution)
                |> assign(:execution_id, execution.id)
                |> assign(:step_executions_count, length(step_executions))
                |> assign(:item_stats_by_step_id, item_stats.by_step_id)
                |> assign(:item_stats_summary, item_stats.summary)
                |> assign(:step_executions_data, step_executions)
                |> assign_raw_execution_data(execution, step_executions)
                |> stream(:step_executions, step_executions, reset: true)

              socket =
                if connected?(socket) do
                  _ = ExecutionPubSub.subscribe_execution(scope, execution.id)
                  socket
                else
                  socket
                end

              {:ok, socket}
            else
              {:ok, redirect_to_workflows(socket, "Execution not found")}
            end

          {:error, :not_found} ->
            {:ok, redirect_to_workflows(socket, "Execution not found")}
        end

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Workspace not found")
         |> redirect(to: ~p"/workspaces")}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    execution_id = Map.get(socket.assigns, :execution_id)

    if execution_id do
      ExecutionPubSub.unsubscribe_execution(execution_id)
    end

    :ok
  end

  @impl true
  def handle_info(
        {:execution_event, %{event_name: event_name, execution_id: execution_id}},
        socket
      )
      when event_name in @execution_lifecycle_events do
    if execution_id == socket.assigns.execution_id do
      {:noreply, refresh_execution(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        {:execution_event, %{event_name: event_name, execution_id: execution_id}},
        socket
      )
      when event_name in @step_lifecycle_events do
    if execution_id == socket.assigns.execution_id do
      {:noreply, refresh_step_executions(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <:page_header>
        <div class="w-full space-y-6">
          <div class="flex flex-col gap-6 lg:flex-row lg:items-end lg:justify-between">
            <div class="space-y-4">
              <div class="flex items-center gap-3">
                <.link
                  id="execution-back-link"
                  navigate={Paths.workflow_show_path(@current_scope, @workflow.id)}
                  class="inline-flex items-center gap-2 rounded-full border border-base-300 bg-base-100 px-4 py-2 text-xs font-semibold text-base-content/80 transition hover:border-base-300 hover:text-base-content"
                >
                  <.icon name="hero-arrow-left" class="size-4" />
                  <span>Back to workflow</span>
                </.link>
              </div>

              <div class="flex flex-wrap items-center gap-3">
                <h1 class="text-3xl font-semibold tracking-tight text-base-content">
                  Execution {short_id(@execution.id)}
                </h1>
                <span class={[
                  "inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold ring-1 ring-inset",
                  status_pill_class(@execution.status)
                ]}>
                  {humanize(@execution.status)}
                </span>
                <span class={[
                  "inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold ring-1 ring-inset",
                  execution_type_class(@execution.execution_type)
                ]}>
                  {execution_type_label(@execution.execution_type)}
                </span>
              </div>

              <p class="max-w-2xl text-sm text-muted">
                Execution triggered via {execution_trigger_label(@execution)} with{" "}
                {@step_executions_count} step
                <%= if @step_executions_count == 1 do %>
                  execution
                <% else %>
                  executions
                <% end %>.
              </p>

              <div class="flex flex-wrap items-center gap-4 text-xs text-base-content/60">
                <div class="flex items-center gap-1">
                  <.icon name="hero-clock" class="size-4" />
                  <span>Started {format_relative_time(@execution.started_at)}</span>
                </div>
                <div class="flex items-center gap-2 rounded-full border border-base-200 bg-base-100 px-3 py-1 text-[11px] font-semibold text-base-content/70">
                  Item runs {@item_stats_summary.total_item_runs}
                </div>
                <div
                  :if={@item_stats_summary.multi_item_steps > 0}
                  class="flex items-center gap-2 rounded-full border border-base-200 bg-base-100 px-3 py-1 text-[11px] font-semibold text-base-content/70"
                >
                  Multi-item steps {@item_stats_summary.multi_item_steps}
                </div>
                <div class="text-[11px] font-mono uppercase tracking-wide">
                  {@execution.id}
                </div>
              </div>
            </div>

            <div class="flex flex-wrap gap-3">
              <.link
                id="execution-workflow-link"
                navigate={Paths.workflow_show_path(@current_scope, @workflow.id)}
                class="inline-flex items-center gap-2 rounded-full border border-base-300 bg-base-100 px-4 py-2 text-xs font-semibold text-base-content/80 transition hover:border-base-300 hover:text-base-content"
              >
                <.icon name="hero-squares-2x2" class="size-4" />
                <span>Workflow details</span>
              </.link>
              <div class="inline-flex items-center gap-2 rounded-full border border-amber-300/50 bg-amber-100/70 px-4 py-2 text-xs font-semibold text-amber-900">
                <.icon name="hero-exclamation-triangle" class="size-4" />
                <span>Runtime unavailable</span>
              </div>
            </div>
          </div>
        </div>
      </:page_header>

      <div class="space-y-8">
        <section id="execution-summary" class="space-y-6">
          <div class="relative overflow-hidden rounded-3xl border border-base-300 bg-base-100 p-6 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md">
            <div class="pointer-events-none absolute -right-16 -top-16 h-40 w-40 rounded-full bg-gradient-to-br from-primary/20 via-accent/10 to-transparent blur-2xl" />

            <div class="relative grid gap-6 lg:grid-cols-3">
              <div class="space-y-4">
                <h2 class="text-sm font-semibold uppercase tracking-[0.2em] text-base-content/60">
                  Overview
                </h2>
                <div class="space-y-3 text-sm">
                  <div class="flex items-center justify-between gap-3">
                    <span class="text-base-content/60">Workflow</span>
                    <span class="font-medium text-base-content">{@workflow.name}</span>
                  </div>
                  <div class="flex items-center justify-between gap-3">
                    <span class="text-base-content/60">Triggered by</span>
                    <span class="font-medium text-base-content">
                      {triggered_by_label(@execution)}
                    </span>
                  </div>
                  <div class="flex items-center justify-between gap-3">
                    <span class="text-base-content/60">Execution type</span>
                    <span class="font-medium text-base-content">
                      {execution_type_label(@execution.execution_type)}
                    </span>
                  </div>
                </div>
              </div>

              <div class="space-y-4">
                <h2 class="text-sm font-semibold uppercase tracking-[0.2em] text-base-content/60">
                  Timing
                </h2>
                <div class="space-y-3 text-sm">
                  <div class="flex items-center justify-between gap-3">
                    <span class="text-base-content/60">Started</span>
                    <span class="font-medium text-base-content">
                      {formatted_timestamp(@execution.started_at)}
                    </span>
                  </div>
                  <div class="flex items-center justify-between gap-3">
                    <span class="text-base-content/60">Completed</span>
                    <span class="font-medium text-base-content">
                      {formatted_timestamp(@execution.completed_at)}
                    </span>
                  </div>
                  <div class="flex items-center justify-between gap-3">
                    <span class="text-base-content/60">Duration</span>
                    <span class="font-medium text-base-content">
                      {format_duration(Execution.duration_us(@execution))}
                    </span>
                  </div>
                </div>
              </div>

              <div class="space-y-4">
                <h2 class="text-sm font-semibold uppercase tracking-[0.2em] text-base-content/60">
                  Trace
                </h2>
                <div class="space-y-3 text-sm">
                  <div class="flex items-center justify-between gap-3">
                    <span class="text-base-content/60">Trace ID</span>
                    <span class="font-mono text-xs text-base-content">
                      {trace_value(@execution)}
                    </span>
                  </div>
                  <div class="flex items-center justify-between gap-3">
                    <span class="text-base-content/60">Correlation</span>
                    <span class="font-mono text-xs text-base-content">
                      {correlation_value(@execution)}
                    </span>
                  </div>
                  <div class="flex items-center justify-between gap-3">
                    <span class="text-base-content/60">Parent Execution</span>
                    <span class="font-mono text-xs text-base-content">
                      {parent_execution_value(@execution)}
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section id="execution-payloads" class="space-y-6">
          <div class="grid gap-6 lg:grid-cols-2">
            <div class="rounded-3xl border border-base-300 bg-base-100 p-6 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md">
              <h2 class="text-lg font-semibold text-base-content flex items-center gap-2">
                <.icon name="hero-bolt" class="size-5 text-primary" /> Trigger Input
              </h2>
              <p class="mt-2 text-xs text-base-content/60">
                Trigger payload used to start the run.
              </p>
              <pre class="mt-4 max-h-72 overflow-auto rounded-2xl bg-base-200/60 p-4 text-[11px] leading-relaxed text-base-content/80">{format_payload(trigger_payload(@execution))}</pre>
            </div>

            <div class="rounded-3xl border border-base-300 bg-base-100 p-6 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md">
              <h2 class="text-lg font-semibold text-base-content flex items-center gap-2">
                <.icon name="hero-squares-2x2" class="size-5 text-primary" /> Context Snapshot
              </h2>
              <p class="mt-2 text-xs text-base-content/60">
                Aggregated outputs from all steps so far.
              </p>
              <pre class="mt-4 max-h-72 overflow-auto rounded-2xl bg-base-200/60 p-4 text-[11px] leading-relaxed text-base-content/80">{format_payload(@execution.context)}</pre>
            </div>

            <div class="rounded-3xl border border-base-300 bg-base-100 p-6 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md">
              <h2 class="text-lg font-semibold text-base-content flex items-center gap-2">
                <.icon name="hero-arrow-up-tray" class="size-5 text-primary" /> Output
              </h2>
              <p class="mt-2 text-xs text-base-content/60">
                Final output from the workflow.
              </p>
              <pre class="mt-4 max-h-72 overflow-auto rounded-2xl bg-base-200/60 p-4 text-[11px] leading-relaxed text-base-content/80">{format_payload(@execution.output)}</pre>
            </div>

            <div class="rounded-3xl border border-base-300 bg-base-100 p-6 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md">
              <h2 class="text-lg font-semibold text-base-content flex items-center gap-2">
                <.icon name="hero-clipboard-document-list" class="size-5 text-primary" /> Metadata
              </h2>
              <p class="mt-2 text-xs text-base-content/60">
                Debug metadata attached to the execution.
              </p>
              <pre class="mt-4 max-h-72 overflow-auto rounded-2xl bg-base-200/60 p-4 text-[11px] leading-relaxed text-base-content/80">{format_payload(@execution.metadata)}</pre>
            </div>
          </div>
        </section>

        <section :if={@execution.error} id="execution-errors" class="space-y-6">
          <div class="rounded-3xl border border-rose-400/40 bg-rose-500/10 p-6 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md">
            <h2 class="text-lg font-semibold text-rose-700 dark:text-rose-300 flex items-center gap-2">
              <.icon name="hero-exclamation-triangle" class="size-5" /> Failure Details
            </h2>
            <p class="mt-2 text-xs text-rose-700/80 dark:text-rose-300/80">
              The run reported a failure. Inspect the error payload below.
            </p>
            <pre class="mt-4 max-h-72 overflow-auto rounded-2xl bg-rose-500/10 p-4 text-[11px] leading-relaxed text-rose-700 dark:text-rose-300">{format_payload(@execution.error)}</pre>
          </div>
        </section>

        <section id="execution-steps" class="space-y-6">
          <div class="flex items-center justify-between">
            <div>
              <h2 class="text-lg font-semibold text-base-content flex items-center gap-2">
                <.icon name="hero-queue-list" class="size-5 text-primary" /> Step Executions
              </h2>
              <p class="mt-1 text-xs text-base-content/60">
                Live status of each step in the execution.
              </p>
            </div>
            <div class="rounded-full border border-base-300 bg-base-100 px-3 py-1 text-xs font-semibold text-base-content/80">
              {@step_executions_count} steps
            </div>
          </div>

          <div
            id="execution-step-list"
            phx-update="stream"
            class="space-y-4"
          >
            <div
              id="execution-step-list-empty"
              class="hidden rounded-3xl border border-base-300 bg-base-100 p-6 text-center text-sm text-base-content/60 only:block"
            >
              No step executions yet.
            </div>

            <div
              :for={{id, step} <- @streams.step_executions}
              id={id}
              class="rounded-3xl border border-base-300 bg-base-100 p-5 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md"
            >
              <div class="grid gap-4 md:grid-cols-12 md:items-start">
                <div class="md:col-span-4 space-y-2">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class="text-sm font-semibold text-base-content">
                      {step.step_id}
                    </span>
                    <span
                      :if={StepExecution.retry?(step)}
                      class="rounded-full border border-amber-400/40 bg-amber-500/10 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-amber-700 dark:text-amber-300"
                    >
                      Retry {step.attempt}
                    </span>
                  </div>
                  <div class="text-xs text-base-content/60">
                    {step.step_type_id || "Unknown step type"}
                  </div>
                  <div class="flex flex-wrap items-center gap-2 text-xs text-base-content/60">
                    <span class={[
                      "inline-flex items-center rounded-full px-2.5 py-1 text-[11px] font-semibold ring-1 ring-inset",
                      status_pill_class(step.status)
                    ]}>
                      {humanize(step.status)}
                    </span>
                    <span
                      :if={step.item_index != nil}
                      class="rounded-full border border-base-200 bg-base-100 px-2 py-1 text-[10px] font-semibold text-base-content/70"
                    >
                      Item {step.item_index + 1}
                      <%= if step.items_total do %>
                        /{step.items_total}
                      <% end %>
                    </span>
                    <span
                      :if={
                        step.item_index == nil && @item_stats_by_step_id[step.step_id] &&
                          @item_stats_by_step_id[step.step_id].items_total > 1
                      }
                      class="rounded-full border border-base-200 bg-base-100 px-2 py-1 text-[10px] font-semibold text-base-content/70"
                    >
                      Items {@item_stats_by_step_id[step.step_id].completed +
                        @item_stats_by_step_id[step.step_id].failed}/{@item_stats_by_step_id[
                        step.step_id
                      ].items_total}
                    </span>
                    <span>
                      Duration {format_duration(StepExecution.duration_us(step))}
                    </span>
                    <span>
                      Queue {format_duration(StepExecution.queue_time_us(step))}
                    </span>
                  </div>
                </div>

                <div class="md:col-span-8 space-y-3">
                  <div class="grid gap-3 md:grid-cols-2">
                    <details class="group rounded-2xl border border-base-200 bg-base-200/40 p-3 text-xs transition hover:border-base-300">
                      <summary class="cursor-pointer font-semibold text-base-content/80 transition">
                        Input: {payload_preview(step.input_data)}
                      </summary>
                      <pre class="mt-3 max-h-56 overflow-auto rounded-xl bg-base-100/80 p-3 text-[11px] leading-relaxed text-base-content/70">{format_payload(step.input_data)}</pre>
                    </details>
                    <details class="group rounded-2xl border border-base-200 bg-base-200/40 p-3 text-xs transition hover:border-base-300">
                      <summary class="cursor-pointer font-semibold text-base-content/80 transition">
                        Output: {payload_preview(step.output_data)}
                      </summary>
                      <pre class="mt-3 max-h-56 overflow-auto rounded-xl bg-base-100/80 p-3 text-[11px] leading-relaxed text-base-content/70">{format_payload(step.output_data)}</pre>
                    </details>
                  </div>

                  <details
                    :if={step.error}
                    class="group rounded-2xl border border-rose-400/40 bg-rose-500/10 p-3 text-xs transition hover:border-rose-400/60"
                  >
                    <summary class="cursor-pointer font-semibold text-rose-700 dark:text-rose-300 transition">
                      Error: {payload_preview(step.error)}
                    </summary>
                    <pre class="mt-3 max-h-56 overflow-auto rounded-xl bg-rose-500/10 p-3 text-[11px] leading-relaxed text-rose-700 dark:text-rose-300">{format_payload(step.error)}</pre>
                  </details>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section id="execution-raw-data" class="space-y-4">
          <div class="rounded-3xl border border-base-300 bg-base-100 p-6 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md">
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <h2 class="text-lg font-semibold text-base-content flex items-center gap-2">
                  <.icon name="hero-code-bracket-square" class="size-5 text-primary" />
                  Raw Execution Data
                </h2>
                <p class="mt-1 text-xs text-base-content/60">
                  Full execution payload with workflow, steps, trigger, and pinned outputs.
                </p>
              </div>
              <span class="rounded-full border border-base-300 bg-base-100 px-3 py-1 text-[11px] font-semibold text-base-content/70">
                JSON
              </span>
            </div>

            <div class="mt-4">
              <.input
                type="textarea"
                id="execution-raw-json"
                name="execution-raw-json"
                value={@raw_execution_json}
                readonly
                rows="18"
                class="w-full min-h-[320px] rounded-2xl border border-base-300 bg-base-100 px-4 py-3 font-mono text-[11px] leading-relaxed text-base-content/80 shadow-sm focus:border-primary focus:outline-none"
              />
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp refresh_execution(socket) do
    case Executions.get_execution(socket.assigns.current_scope, socket.assigns.execution_id) do
      {:ok, execution} ->
        step_executions = socket.assigns.step_executions_data || []

        socket
        |> assign(:execution, execution)
        |> assign_raw_execution_data(execution, step_executions)

      {:error, _} ->
        socket
    end
  end

  defp refresh_step_executions(socket) do
    step_executions =
      Executions.list_step_executions(socket.assigns.current_scope, socket.assigns.execution)

    item_stats = build_item_stats(step_executions)

    socket
    |> assign(:step_executions_count, length(step_executions))
    |> assign(:item_stats_by_step_id, item_stats.by_step_id)
    |> assign(:item_stats_summary, item_stats.summary)
    |> assign(:step_executions_data, step_executions)
    |> assign_raw_execution_data(socket.assigns.execution, step_executions)
    |> stream(:step_executions, sort_step_executions(step_executions), reset: true)
  end

  defp redirect_to_workflows(socket, message) do
    socket
    |> put_flash(:error, message)
    |> redirect(to: Paths.workflows_index_path(socket.assigns.current_scope))
  end

  defp execution_trigger_label(execution), do: ShowPresenter.execution_trigger_label(execution)
  defp trigger_payload(execution), do: ShowPresenter.trigger_payload(execution)
  defp trace_value(execution), do: ShowPresenter.trace_value(execution)
  defp correlation_value(execution), do: ShowPresenter.correlation_value(execution)
  defp parent_execution_value(execution), do: ShowPresenter.parent_execution_value(execution)
  defp triggered_by_label(execution), do: ShowPresenter.triggered_by_label(execution)
  defp execution_type_label(type), do: ShowPresenter.execution_type_label(type)
  defp execution_type_class(type), do: ShowPresenter.execution_type_class(type)
  defp status_pill_class(status), do: ShowPresenter.status_pill_class(status)
  defp humanize(value), do: ShowPresenter.humanize(value)

  defp sort_step_executions(step_executions),
    do: ShowPresenter.sort_step_executions(step_executions)

  defp payload_preview(payload), do: ShowPresenter.payload_preview(payload)
  defp format_payload(payload), do: ShowPresenter.format_payload(payload)

  defp assign_raw_execution_data(socket, %Execution{} = execution, step_executions) do
    raw_json =
      ShowPresenter.raw_execution_json(socket.assigns.workflow, execution, step_executions)

    assign(socket, :raw_execution_json, raw_json)
  end

  defp build_item_stats(step_executions), do: ShowPresenter.build_item_stats(step_executions)
end
