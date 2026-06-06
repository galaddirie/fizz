# 7. Debug View — Version-Pinned Run Replay

## Context

The debug route (`/projects/:pid/workflows/:did/edit/runs/:rid`) exists and loads execution data, but currently renders the **current draft** on the canvas instead of the version that was actually executed. When the draft has diverged — steps added, removed, or reconfigured — the execution overlays don't match the graph, making debugging impossible.

The data model already supports version-pinned replay: `WorkflowRun` stores `workflow_definition_version_id`, and `WorkflowDefinitionVersion` stores the full step/connection/group structure. The fix is entirely in the view layer.

**Specs covered:** `editor.debug_view` (full), `editor.execution.req_debug_mode` (superseded and refined by the new spec)

---

## Phase 1: Version-Pinned Graph Rendering

### Goal

Make the debug view render the executed version's graph, not the current draft.

### What exists

- `load_editor/2` in `editor.ex` always calls `Workflows.edit_definition(scope, definition_id)` which returns the current draft
- `workflow_prop/1` always passes `encode_draft(draft)` as the graph source
- `WorkflowRun` has `workflow_definition_version_id` FK
- `WorkflowDefinitionVersion` has embedded `steps`, `connections`, `step_groups`

### What to build

#### 1. New context function: `Workflows.get_run_with_version/2`

```elixir
@spec get_run_with_version(Scope.t(), run_id :: String.t()) ::
  {:ok, WorkflowRun.t()} | {:error, :run_not_found}
```

Loads the run and preloads `workflow_definition_version` with its embedded associations. This is the single query that gives us the version snapshot.

#### 2. Modify `load_editor/2` to branch on `:debug` action

When `live_action == :debug`:

1. Load the run via `get_run_with_version/2`
2. Use `run.workflow_definition_version` as the graph source instead of calling `edit_definition`
3. Still load the definition (for name, metadata) but **do not** load or create a draft
4. Skip `maybe_connect_draft_session` entirely — assign empty defaults for `collab_seq`, `presences`, `undo_state`, `save_status`

```elixir
defp load_editor(socket, params) when socket.assigns.live_action == :debug do
  with {:ok, scope} <- build_scope(params),
       {:ok, definition} <- Workflows.get_definition(scope, definition_id),
       {:ok, run} <- Workflows.get_run_with_version(scope, run_id),
       {:ok, step_executions} <- Workflows.list_run_step_executions(scope, run_id) do

    version = run.workflow_definition_version

    socket
    |> assign(:definition, definition)
    |> assign(:draft, version)  # the version IS the graph source
    |> assign(:execution, encode_execution(run))
    |> assign(:step_executions, step_executions)
    |> assign(:debug_execution_id, run_id)
    |> assign(:debug_mode, true)
    |> assign_debug_defaults()
    |> maybe_subscribe_to_run(run)
  end
end
```

`assign_debug_defaults/1` sets `collab_seq: 0`, `presences: []`, `undo_state: nil`, `save_status: "read_only"`, `save_error: nil`, `credential_options: []`.

`maybe_subscribe_to_run/2` subscribes to PubSub only if the run is non-terminal.

#### 3. Pass `debug_mode` prop to Vue

Add `debug_mode` to the props passed to the WorkflowEditor component. When true, the Vue layer treats the session as read-only.

### Tests

- Load debug view for a completed run → assert the rendered steps match the executed version, not the current draft
- Load debug view for a run whose version has since been superseded by a new draft with different steps → assert version-pinned rendering
- Assert DraftSession is not joined (no GenServer call)

### Boundaries

- Do NOT change how `:edit` mode loads — it continues to use the current draft and DraftSession
- Do NOT implement the drift banner yet (Phase 2)

---

## Phase 2: Read-Only Canvas & Drift Detection

### Goal

Disable mutations in debug mode and show users when the executed version differs from the current state.

### What to build

#### 1. Vue: Read-only mode

When the `debugMode` prop is true:

- **Toolbar**: Hide "Add Step" button, disable structural actions. Keep pan/zoom, step selection, trace panel toggle.
- **Canvas**: Disable drag-to-move for steps, drag-to-connect for edges, right-click context menu items that mutate (delete, duplicate). Keep click-to-select, click-to-inspect.
- **Step config panel**: Show I/O inspection panes but hide save/apply buttons. Pin output buttons remain active (useful for downstream debugging).
- **Keyboard shortcuts**: Disable delete, undo, redo, paste. Keep navigation shortcuts.

Implementation: Add a `readonly` computed in `useWorkflowEditor` derived from the `debugMode` prop. Gate mutation functions on `!readonly.value`. This is simpler than disabling individual UI elements — the composable simply no-ops.

#### 2. Drift banner

Compute drift on the server:

```elixir
defp compute_drift(run_version, definition) do
  current_hash = current_published_or_draft_hash(definition)

  cond do
    is_nil(current_hash) -> :no_reference
    current_hash == run_version.compiled_hash -> :no_drift
    true -> :drifted
  end
end
```

Pass drift info as a prop:

```elixir
%{
  drift_status: :drifted | :no_drift | :no_reference,
  executed_version_number: version.version,
  executed_version_published_at: version.published_at
}
```

The Vue component renders a banner at the top of the canvas:

```
┌─────────────────────────────────────────────────────────────┐
│ ⚠ This run executed on Version 3 (published Mar 28).       │
│   The current workflow definition has changed since then.   │
│   [View Current Draft]  [View Runs for Version 3]           │
└─────────────────────────────────────────────────────────────┘
```

When drift is `:no_drift`, show a subtle "Matches current definition" badge instead.

#### 3. Navigation links

- **"View Current Draft"**: `<Link navigate={~p"/projects/#{pid}/workflows/#{did}/edit"}>` — exits debug mode
- **"View Runs for Version 3"**: `<Link navigate={~p"/projects/#{pid}/workflows/#{did}/runs?version_id=#{vid}"}>` — filters run list (requires run list to support `version_id` query param)

### Tests

- In debug mode, attempt a structural mutation via pushEvent → assert no DraftSession call, no state change
- Load debug view where run version hash differs from current draft hash → assert drift banner appears with correct version number
- Load debug view where hashes match → assert "matches current definition" badge

### Boundaries

- Do NOT implement the version-filtered runs list in this phase (just emit the link; the runs page can filter later)

---

## Phase 3: Execution Overlay Integrity

### Goal

Ensure step execution overlays map perfectly to version-pinned nodes with no orphans or phantoms.

### What to build

#### 1. Step ID mapping validation

The `useWorkflowGraph` composable already maps `step_executions` to nodes by `step_id`. With the version-pinned graph, this mapping is inherently correct because the steps and executions come from the same version.

Add a development-mode assertion (stripped in production builds) that verifies:
- Every `step_id` in `stepExecutions` has a corresponding node in the graph
- Log a warning if any execution references an unknown step (indicates a data integrity issue, not a rendering bug)

#### 2. Fan-out and retry display

The `ExecutionTracePanel` already handles multi-item steps and retry attempts. Verify these work correctly when:
- The version has a splitter step that produced fan-out items
- A step failed and was retried (multiple attempts for the same step_id)

No new code expected — just test coverage.

### Tests

- Debug view with a fan-out step → assert trace panel shows item breakdown
- Debug view with a retried step → assert trace panel shows all attempts
- Development mode: inject an execution with a fake step_id → assert console warning

### Boundaries

- Do NOT build execution replay / time-travel scrubbing (follow-up work)
- Do NOT build execution comparison (side-by-side runs)

---

## Assumptions

1. **Version always exists**: A run's `workflow_definition_version_id` always points to a valid, undeleted version. Versions are never hard-deleted (they may be archived but the record persists).
2. **Test run versions**: When a test run compiles the draft in-memory, the draft version is persisted (via `DraftSession.persist_now/1`) before the run starts, so `workflow_definition_version_id` points to a valid version snapshot.
3. **Step IDs are stable within a version**: A step's ID never changes within a given version — it is assigned on creation and carried through to the execution log.
4. **PubSub contract unchanged**: The Worker's broadcast events (step_started, step_completed, etc.) include `step_id` matching the version's step IDs.

## Follow-Up Work

- **Execution replay / time-travel**: Scrub through execution history step-by-step with a timeline control
- **Partial re-execution**: Re-run from a specific step with injected input, pinned to the same version
- **Execution comparison**: Side-by-side two runs of the same or different versions
- **Breakpoints**: Pause execution at specific steps for live inspection
- **Version diff overlay**: In drift mode, optionally show a diff highlighting what changed between the executed version and the current draft
