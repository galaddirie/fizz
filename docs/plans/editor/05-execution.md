# 5. Execution & Debugging

## Context

The execution runtime is fully built: Worker GenServer with 3-phase loop, SQLite checkpoint store, lease management, durable timers, signal routing. The editor needs to surface execution state in real-time without leaving the editor. The POC has execution overlay components. This document defines the production execution visibility system.

---

## Test Runs from the Editor

### Triggering a Test Run

1. User clicks "Run Test" (full workflow) or "Run Node" (single step) in toolbar/context menu
2. Vue emits `run_test` or `run_node` command
3. LiveView handles:

```elixir
def handle_event("editor_command", %{"type" => "run_test"}, socket) do
  # 1. Persist current draft
  DraftSession.persist_now(socket.assigns.draft.id)

  # 2. Compile the draft (without publishing)
  case Workflows.Compiler.compile(socket.assigns.draft) do
    {:ok, workflow, compiled_hash} ->
      # 3. Start a run tagged as editor test
      {:ok, run} = Workflows.start_run(
        socket.assigns.current_scope,
        socket.assigns.draft,
        %{},  # input (or from trigger config)
        triggered_by: %{"kind" => "editor_test", "user_id" => user_id}
      )

      # 4. Subscribe to run events
      Phoenix.PubSub.subscribe(Fizz.PubSub, "workflow_run:#{run.id}")

      {:noreply, assign(socket, execution: run, debug_execution_id: run.id)}

    {:error, errors} ->
      # Push compilation errors to Vue
      {:noreply, push_event(socket, "compilation_errors", %{errors: errors})}
  end
end
```

**Key decision:** Test runs compile the draft in-memory without publishing. `Compiler.compile/1` works on any `WorkflowDefinitionVersion` regardless of status. The run is tagged with `triggered_by.kind = "editor_test"` to distinguish from production runs.

### Run Node (Single Step)

For "Run Node", the system needs to:
1. Identify the step and its upstream dependencies
2. Use pinned outputs from upstream steps as input (from `editor_state.pinned_outputs`)
3. If no pinned output exists, show an error: "Pin output from upstream step first"
4. Execute only the target step with the assembled input context

**New backend contract:**
```elixir
@spec run_single_step(Scope.t(), WorkflowDefinitionVersion.t(), step_id :: String.t(), input :: map()) ::
  {:ok, %{output: term(), duration_us: integer()}} | {:error, term()}
```

This compiles and executes a single step executor without creating a full `WorkflowRun`. Returns the result directly to the LiveView.

### Cancel Execution

```elixir
def handle_event("editor_command", %{"type" => "cancel_execution"}, socket) do
  if socket.assigns.execution do
    Workflows.cancel_run(socket.assigns.current_scope, socket.assigns.execution.id)
  end
  {:noreply, socket}
end
```

---

## PubSub: Execution Event Broadcasting

### Topics

| Topic | Purpose |
|-------|---------|
| `"workflow_run:#{run_id}"` | All events for a specific run |
| `"workflow_run:#{run_id}:step:#{step_id}"` | Per-step events (optional, for fine-grained subscriptions) |

### Message Shapes

The Worker GenServer broadcasts these events during execution:

```elixir
# Run-level events
{:run_status_changed, %{
  run_id: String.t(),
  status: :running | :completed | :failed | :cancelled | :sleeping,
  timestamp: DateTime.t()
}}

# Step-level events
{:step_queued, %{
  run_id: String.t(),
  step_id: String.t(),
  attempt: integer(),
  queued_at: DateTime.t()
}}

{:step_started, %{
  run_id: String.t(),
  step_id: String.t(),
  attempt: integer(),
  started_at: DateTime.t()
}}

{:step_completed, %{
  run_id: String.t(),
  step_id: String.t(),
  attempt: integer(),
  output: term(),           # full output data
  output_summary: map(),    # truncated for canvas display
  duration_us: integer(),
  completed_at: DateTime.t()
}}

{:step_failed, %{
  run_id: String.t(),
  step_id: String.t(),
  attempt: integer(),
  error: %{type: String.t(), message: String.t(), details: map()},
  duration_us: integer(),
  failed_at: DateTime.t()
}}

{:step_skipped, %{
  run_id: String.t(),
  step_id: String.t(),
  reason: String.t(),
  skipped_at: DateTime.t()
}}

# Fan-out events
{:fan_out_started, %{
  run_id: String.t(),
  step_id: String.t(),
  items_total: integer()
}}

{:fan_out_item_completed, %{
  run_id: String.t(),
  step_id: String.t(),
  item_index: integer(),
  items_total: integer(),
  status: :completed | :failed,
  duration_us: integer()
}}

{:fan_out_completed, %{
  run_id: String.t(),
  step_id: String.t(),
  completed: integer(),
  failed: integer(),
  total: integer(),
  duration_us: integer()
}}
```

### Worker Broadcasting (new — needs to be added to Worker)

The Worker GenServer needs to broadcast these events. Add a `broadcast/2` helper:

```elixir
# In Fizz.Workflows.Runner.Worker
defp broadcast(run_id, event) do
  Phoenix.PubSub.broadcast(Fizz.PubSub, "workflow_run:#{run_id}", event)
end
```

Call points:
- After `Workflow.run/2` returns dispatched runnables → `:step_queued`
- Before executing a runnable → `:step_started`
- After runnable completes → `:step_completed` or `:step_failed`
- After skip decision → `:step_skipped`
- On status transitions → `:run_status_changed`
- On fan-out orchestration → fan-out events

---

## LiveView: Execution Event Handling

```elixir
# Subscribe when execution starts
def handle_event("editor_command", %{"type" => "run_test"}, socket) do
  # ... start run ...
  Phoenix.PubSub.subscribe(Fizz.PubSub, "workflow_run:#{run.id}")
  # ...
end

# Handle step events
def handle_info({:step_started, payload}, socket) do
  step_executions = update_step_execution(socket.assigns.step_executions, payload)
  {:noreply, assign(socket, step_executions: step_executions)}
end

def handle_info({:step_completed, payload}, socket) do
  step_executions = update_step_execution(socket.assigns.step_executions, payload)
  {:noreply, assign(socket, step_executions: step_executions)}
end

def handle_info({:run_status_changed, %{status: status} = payload}, socket) do
  execution = %{socket.assigns.execution | status: status}

  socket = assign(socket, execution: execution)

  # Unsubscribe on terminal status
  if status in [:completed, :failed, :cancelled] do
    Phoenix.PubSub.unsubscribe(Fizz.PubSub, "workflow_run:#{payload.run_id}")
  end

  {:noreply, socket}
end
```

The `step_executions` assign is a list of maps matching the `StepExecution` TypeScript interface. Updated incrementally as events arrive.

---

## Canvas Execution Overlay

### Node Status Display (exists in `Node.vue`)

The POC already renders per-node status indicators. The `useWorkflowNodes` composable merges execution data into `StepNodeData`:

```typescript
// In useWorkflowNodes, when building node data:
{
  status: stepExecution?.status,  // pending|queued|running|completed|failed|skipped
  stats: {
    duration_us: stepExecution?.duration_us,
    bytes: stepExecution?.output_data ? JSON.stringify(stepExecution.output_data).length : undefined,
    out: stepExecution?.output_item_count
  },
  itemStats: stepExecution?.items_total ? {
    isMultiItem: true,
    itemsTotal: stepExecution.items_total,
    completed: fanOutCompleted,
    failed: fanOutFailed,
    running: fanOutRunning
  } : undefined
}
```

### Edge Status (exists in `Edge.vue`)

Edges inherit the status color of their source node. Running edges animate (dashed line animation). Completed edges show item count badges.

### Execution Overlay Bar (exists in `ExecutionOverlay.vue`)

Shows at the top of the canvas during execution:
- Run status badge (Running / Completed / Failed)
- Total duration
- Step progress (N/M steps completed)
- Cancel button
- "View Full Run" link (navigates to run detail page)

---

## Execution Trace Panel

### `ExecutionTracePanel.vue` (exists)

Side panel showing chronological execution trace:

```
┌─ Execution Trace ──────────────────────┐
│ ▶ Fetch Orders     ✓ 234ms   3 items   │
│   └─ Item 0        ✓ 78ms              │
│   └─ Item 1        ✓ 82ms              │
│   └─ Item 2        ✓ 74ms              │
│ ▶ Filter Orders    ✓ 12ms   2 items    │
│ ▶ Send Email       ✗ 1.2s   Error      │
│   └─ Attempt 1     ✗ 600ms  Timeout    │
│   └─ Attempt 2     ✗ 600ms  Timeout    │
│ ○ Update CRM       ⏳ Pending          │
└─────────────────────────────────────────┘
```

Each trace entry shows:
- Step name and icon
- Status indicator (✓ completed, ✗ failed, ⏳ pending, ▶ running, ⏭ skipped)
- Duration
- Output item count (for fan-out)
- Expandable: iteration details for fan-out, retry attempts
- Click to open step config modal's Output pane with full I/O data

### Trace Entry Data (`TraceEntry` type — exists)

```typescript
interface TraceEntry {
  id: string;
  step_id: string;
  step_name: string;
  step_type_id?: string;
  status: StepExecutionStatus;
  duration_us?: number;
  timestamp?: string;
  error?: string;
  item_index?: number | null;
  items_total?: number | null;
  isMultiItem?: boolean;
  iterations?: Array<{
    id: string;
    status: StepExecutionStatus;
    duration_us?: number;
    input_data?: unknown;
    output_data?: unknown;
    error?: string;
    item_index?: number | null;
  }>;
  input_data?: unknown;
  output_data?: unknown;
}
```

### I/O Data Inspection

**Step output:** Shown in `StepConfigOutputPane.vue` using the `DataViewer` component family (JSON view + tree view). The user can:
- View raw JSON output
- Browse tree structure
- Copy values
- Pin output for use in expression previews and downstream step testing

**Step input:** Shown in `StepConfigContextPane.vue`. Assembled from upstream step outputs based on connections.

**Data loading strategy:** Full I/O data is NOT pushed for all steps in the `step_executions` assign (too large). Instead:
- `step_executions` includes `output_summary` (truncated) for canvas display
- Full `input_data` and `output_data` are loaded on-demand when the user opens the config modal for a specific step
- The LiveView handles a `load_step_io` event that queries the Worker or SQLite store

```elixir
def handle_event("editor_command", %{"type" => "load_step_io", "payload" => %{"step_id" => step_id}}, socket) do
  case load_step_execution_data(socket.assigns.execution.id, step_id) do
    {:ok, %{input_data: input, output_data: output}} ->
      {:noreply, push_event(socket, "step_io_loaded", %{step_id: step_id, input_data: input, output_data: output})}
    {:error, _} ->
      {:noreply, socket}
  end
end
```

---

## Debug Mode

When navigating to `/projects/:project_id/workflows/:definition_id/edit/runs/:run_id`:

1. LiveView loads the specified run and its step executions
2. Subscribes to `"workflow_run:#{run_id}"` PubSub topic
3. Sets `debug_execution_id` assign
4. Canvas shows execution overlay with historical data
5. For completed/failed runs: all data is already available, no live updates needed
6. For running runs: live updates stream in via PubSub

Debug mode is read-only for execution state but the draft is still editable (the user might fix a bug while viewing the failed run).

---

## What Exists vs. What's New

**Exists:**
- `ExecutionOverlay.vue` — run status bar
- `ExecutionTracePanel.vue` — chronological trace view
- `useWorkflowExecutionState` composable — execution state management
- `useStepExecution` composable — per-step execution data
- `DataViewer` components — JSON/tree I/O visualization
- `StepExecution` / `Execution` / `TraceEntry` TypeScript types
- `workflowTrace.ts` — trace formatting utilities
- Worker GenServer (full execution engine)
- SQLite checkpoint store

**New:**
- PubSub broadcasting from Worker GenServer (step-level events)
- LiveView PubSub subscription and `step_executions` incremental updates
- `run_single_step/4` backend API for "Run Node"
- On-demand I/O data loading (`load_step_io` event)
- Debug mode LiveView action (`:debug` live_action)
- Worker `broadcast/2` helper
- `output_summary` field in step execution events (truncated for canvas display)

---

## Assumptions

1. **Test run compilation:** `Compiler.compile/1` works on unpublished drafts. The compiler checks DAG validity and expression integrity but not version status.
2. **Worker PubSub:** Adding PubSub broadcasting to the Worker doesn't affect execution performance. Events are fire-and-forget (broadcast, don't wait for subscribers).
3. **I/O data size:** Step outputs can be large (MB+). Must load on-demand, not push all at once. The `output_summary` truncation handles canvas display.
4. **Single active test run:** The editor tracks one active execution at a time. Starting a new test run while one is running cancels the previous one.

## Follow-Up Work

- Execution replay / time-travel debugging (scrub through execution history)
- Partial execution (run from a specific step with injected input)
- Execution comparison (side-by-side two runs)
- Breakpoints (pause execution at specific steps for inspection)
- Execution cost tracking (API call costs, token usage for AI steps)
