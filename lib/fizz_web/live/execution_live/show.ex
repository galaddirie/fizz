defmodule FizzWeb.ExecutionLive.Show do
  @moduledoc """
  LiveView for showing an execution.
  """
  use FizzWeb, :live_view

  alias Fizz.Executions
  alias Fizz.Executions.{Execution, StepExecution}
  alias Fizz.Executions.PubSub, as: ExecutionPubSub
  import FizzWeb.Formatters

  @impl true
  def mount(%{"workflow_id" => workflow_id, "execution_id" => execution_id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Executions.get_execution_with_steps(scope, execution_id) do
      {:ok, execution} ->
        if execution.workflow_id == workflow_id do
          step_executions = sort_step_executions(execution.step_executions)
          item_stats = build_item_stats(step_executions)

          socket =
            socket
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
  def handle_info({event, %Execution{id: execution_id}}, socket)
      when event in [:execution_started, :execution_updated, :execution_completed] do
    if execution_id == socket.assigns.execution_id do
      {:noreply, refresh_execution(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:execution_failed, %Execution{id: execution_id}, _error}, socket) do
    if execution_id == socket.assigns.execution_id do
      {:noreply, refresh_execution(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({event, payload}, socket)
      when event in [:step_started, :step_completed, :step_failed] do
    payload_execution_id = fetch_payload_value(payload, :execution_id)

    if payload_execution_id == socket.assigns.execution_id do
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
                  navigate={~p"/workflows/#{@workflow.id}"}
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
                navigate={~p"/workflows/#{@workflow.id}"}
                class="inline-flex items-center gap-2 rounded-full border border-base-300 bg-base-100 px-4 py-2 text-xs font-semibold text-base-content/80 transition hover:border-base-300 hover:text-base-content"
              >
                <.icon name="hero-squares-2x2" class="size-4" />
                <span>Workflow details</span>
              </.link>
              <.link
                id="execution-debug-link"
                navigate={~p"/workflows/#{@workflow.id}/edit?debug_execution_id=#{@execution.id}"}
                class="inline-flex items-center gap-2 rounded-full border border-amber-400/40 bg-amber-500/10 px-4 py-2 text-xs font-semibold text-amber-800 transition hover:border-amber-400/70 hover:text-amber-900 dark:text-amber-200 dark:hover:text-amber-100"
              >
                <.icon name="hero-bug-ant" class="size-4" />
                <span>Debug in editor</span>
              </.link>
              <.link
                id="execution-edit-link"
                navigate={~p"/workflows/#{@workflow.id}/edit"}
                class="inline-flex items-center gap-2 rounded-full border border-transparent bg-primary px-4 py-2 text-xs font-semibold text-primary-content shadow-sm transition hover:bg-primary/90"
              >
                <.icon name="hero-play" class="size-4" />
                <span>Open editor</span>
              </.link>
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
            <div class="hidden rounded-3xl border border-base-300 bg-base-100 p-6 text-center text-sm text-base-content/60 only:block">
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
    |> redirect(to: ~p"/workflows")
  end

  defp execution_trigger_label(%Execution{} = execution) do
    execution
    |> trigger_type()
    |> humanize()
  end

  defp trigger_type(%Execution{trigger: %Execution.Trigger{type: type}}), do: type
  defp trigger_type(_), do: nil

  defp trigger_payload(%Execution{trigger: %Execution.Trigger{data: data}}), do: data
  defp trigger_payload(_), do: nil

  defp trace_value(%Execution{metadata: %Execution.Metadata{trace_id: trace_id}}),
    do: trace_id || "-"

  defp trace_value(_), do: "-"

  defp correlation_value(%Execution{
         metadata: %Execution.Metadata{correlation_id: correlation_id}
       }),
       do: correlation_id || "-"

  defp correlation_value(_), do: "-"

  defp parent_execution_value(%Execution{
         metadata: %Execution.Metadata{parent_execution_id: parent_execution_id}
       }),
       do: parent_execution_id || "-"

  defp parent_execution_value(_), do: "-"

  defp triggered_by_label(%Execution{triggered_by_user: %Fizz.Accounts.User{email: email}}),
    do: email

  defp triggered_by_label(%Execution{triggered_by_user_id: nil}), do: "System"
  defp triggered_by_label(_), do: "Unknown"

  defp execution_type_label(nil), do: "-"
  defp execution_type_label(type), do: humanize(type)

  defp execution_type_class(:production),
    do:
      "bg-emerald-500/10 text-emerald-700 ring-emerald-500/30 dark:bg-emerald-500/20 dark:text-emerald-300"

  defp execution_type_class(:preview),
    do: "bg-sky-500/10 text-sky-700 ring-sky-500/30 dark:bg-sky-500/20 dark:text-sky-300"

  defp execution_type_class(:partial),
    do:
      "bg-amber-500/10 text-amber-700 ring-amber-500/30 dark:bg-amber-500/20 dark:text-amber-300"

  defp execution_type_class(_), do: "bg-base-200/60 text-base-content/70 ring-base-200"

  defp status_pill_class(:completed),
    do:
      "bg-emerald-500/10 text-emerald-700 ring-emerald-500/30 dark:bg-emerald-500/20 dark:text-emerald-300"

  defp status_pill_class(:failed),
    do: "bg-rose-500/10 text-rose-700 ring-rose-500/30 dark:bg-rose-500/20 dark:text-rose-300"

  defp status_pill_class(:running),
    do: "bg-sky-500/10 text-sky-700 ring-sky-500/30 dark:bg-sky-500/20 dark:text-sky-300"

  defp status_pill_class(:pending),
    do:
      "bg-amber-500/10 text-amber-700 ring-amber-500/30 dark:bg-amber-500/20 dark:text-amber-300"

  defp status_pill_class(:paused),
    do:
      "bg-amber-500/10 text-amber-700 ring-amber-500/30 dark:bg-amber-500/20 dark:text-amber-300"

  defp status_pill_class(:cancelled), do: "bg-base-200/60 text-base-content/70 ring-base-200"

  defp status_pill_class(:timeout),
    do: "bg-rose-500/10 text-rose-700 ring-rose-500/30 dark:bg-rose-500/20 dark:text-rose-300"

  defp status_pill_class(:queued),
    do:
      "bg-violet-500/10 text-violet-700 ring-violet-500/30 dark:bg-violet-500/20 dark:text-violet-300"

  defp status_pill_class(:skipped), do: "bg-base-200/60 text-base-content/70 ring-base-200"
  defp status_pill_class(_), do: "bg-base-200/60 text-base-content/70 ring-base-200"

  defp humanize(nil), do: "-"

  defp humanize(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp humanize(value), do: to_string(value)

  defp sort_step_executions(step_executions) do
    Enum.sort_by(step_executions, fn step ->
      case step.inserted_at || step.started_at do
        nil -> 0
        datetime -> DateTime.to_unix(datetime, :microsecond)
      end
    end)
  end

  defp fetch_payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp fetch_payload_value(_payload, _key), do: nil

  defp payload_preview(nil), do: "-"

  defp payload_preview(payload) do
    payload
    |> inspect(limit: 6, printable_limit: 200, pretty: true)
    |> String.replace(~r/\s+/, " ")
    |> truncate(90)
  end

  defp truncate(value, max) when is_binary(value) and byte_size(value) > max do
    String.slice(value, 0, max) <> "..."
  end

  defp truncate(value, _max), do: value

  defp format_payload(nil), do: "-"

  defp format_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(payload, pretty: true, limit: :infinity)
    end
  end

  defp assign_raw_execution_data(socket, %Execution{} = execution, step_executions) do
    workflow = socket.assigns.workflow

    raw_payload = %{
      workflow: workflow_raw(workflow),
      execution: execution_raw(execution),
      trigger: execution.trigger,
      context: execution.context,
      output: execution.output,
      error: execution.error,
      metadata: execution.metadata,
      pinned: pinned_data(execution),
      step_executions: Enum.map(step_executions, &step_execution_raw/1)
    }

    assign(socket, :raw_execution_json, format_payload(raw_payload))
  end

  defp workflow_raw(nil), do: nil

  defp workflow_raw(workflow) do
    # Load published version and draft if not already loaded
    workflow = Fizz.Repo.preload(workflow, [:published_version, :draft])

    base_workflow =
      Map.take(workflow, [
        :id,
        :name,
        :description,
        :status,
        :public,
        :current_version_tag,
        :published_version_id,
        :user_id,
        :inserted_at,
        :updated_at
      ])

    # Include full workflow definition from published version or draft
    definition =
      case workflow.published_version do
        %{} = published_version ->
          %{
            version_tag: published_version.version_tag,
            steps: published_version.steps,
            connections: published_version.connections,
            source_hash: published_version.source_hash,
            published_at: published_version.published_at,
            source: "published"
          }

        nil ->
          case workflow.draft do
            %{} = draft ->
              %{
                version_tag: nil,
                steps: draft.steps,
                connections: draft.connections,
                source_hash: nil,
                published_at: nil,
                source: "draft"
              }

            _ ->
              nil
          end
      end

    Map.put(base_workflow, :definition, definition)
  end

  defp execution_raw(%Execution{} = execution) do
    base =
      Map.take(execution, [
        :id,
        :workflow_id,
        :status,
        :execution_type,
        :trigger,
        :context,
        :output,
        :error,
        :waiting_for,
        :started_at,
        :completed_at,
        :expires_at,
        :metadata,
        # :runic_log,
        :triggered_by_user_id,
        :inserted_at,
        :updated_at
      ])

    base
  end

  defp step_execution_raw(step_execution) do
    Map.take(step_execution, [
      :id,
      :execution_id,
      :step_id,
      :step_type_id,
      :status,
      :input_data,
      :output_data,
      :output_item_count,
      :item_index,
      :items_total,
      :error,
      :attempt,
      :retry_of_id,
      :queued_at,
      :started_at,
      :completed_at,
      :metadata,
      :inserted_at,
      :updated_at
    ])
  end

  defp build_item_stats(step_executions) do
    by_step_id =
      step_executions
      |> Enum.group_by(& &1.step_id)
      |> Enum.into(%{}, fn {step_id, executions} ->
        items_total =
          executions
          |> Enum.find_value(fn se -> se.items_total end) ||
            if(length(executions) > 1, do: length(executions), else: 1)

        completed = Enum.count(executions, &(&1.status == :completed))
        failed = Enum.count(executions, &(&1.status == :failed))
        running = Enum.count(executions, &(&1.status == :running))
        skipped = Enum.count(executions, &(&1.status == :skipped))

        {step_id,
         %{
           items_total: items_total,
           completed: completed,
           failed: failed,
           running: running,
           skipped: skipped,
           count: length(executions)
         }}
      end)

    summary = %{
      total_item_runs: length(step_executions),
      multi_item_steps: Enum.count(by_step_id, fn {_id, stats} -> stats.items_total > 1 end)
    }

    %{by_step_id: by_step_id, summary: summary}
  end

  defp pinned_data(%Execution{} = execution) do
    extras = execution.metadata && execution.metadata.extras

    pinned_steps =
      case extras do
        %{} -> Map.get(extras, :pinned_steps) || Map.get(extras, "pinned_steps") || []
        _ -> []
      end

    pinned_outputs =
      if is_list(pinned_steps) and is_map(execution.context) do
        Map.take(execution.context, pinned_steps)
      else
        %{}
      end

    %{
      pinned_steps: pinned_steps,
      pinned_outputs: pinned_outputs,
      disabled_steps: fetch_metadata_list(extras, :disabled_steps)
    }
  end

  defp fetch_metadata_list(extras, key) when is_map(extras) do
    Map.get(extras, key) || Map.get(extras, Atom.to_string(key)) || []
  end

  defp fetch_metadata_list(_extras, _key), do: []
end
