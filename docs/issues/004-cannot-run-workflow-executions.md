# ISSUE-004: Cannot Run or Trigger Workflow Executions from Draft Editor

**Priority:** High
**Component:** Workflow Editor / Execution
**Status:** Open

## Summary

Users cannot run or trigger workflow executions from the draft editor. The "Run Test" functionality does not start an execution, or the execution fails silently.

## Current Behavior

The `run_test` event handler (`editor.ex:124`) calls `run_test/1` (`editor.ex:561-580`), which:

1. Persists the draft via `DraftSession.persist_now/1`
2. Compiles the draft via `Compiler.compile/1`
3. On success, calls `start_editor_test_run/2` (`editor.ex:582-590`)
4. `start_editor_test_run/2` calls `Workflows.start_run/4` with **empty input `%{}`** and `triggered_by: %{"kind" => "editor_test", ...}`

Additionally, the `run_node` event (`editor.ex:127-128`) is explicitly stubbed with a flash message: "Execution controls are wired in Phase 4."

## Potential Failure Points

1. **Draft persistence fails** — If `DraftSession.persist_now/1` returns an error (see ISSUE-001), the run never starts. The error is shown as a flash but may be missed.

2. **Compilation fails** — If the draft has validation errors, `Compiler.compile/1` returns `{:error, errors}` and the run is aborted. Compilation errors are pushed to the client as `compilation_errors` events but may not be displayed prominently.

3. **Empty input for manual triggers** — `start_editor_test_run/2` always passes `%{}` as input. For workflows with a manual trigger that expects input data (via `input_schema`), this may cause the trigger step or subsequent steps to fail.

4. **Run worker fails to start** — `Workflows.start_run/4` creates a run record and starts a worker process. If the worker fails to initialize (e.g., checkpoint store issues), the run may be stuck in `:pending` status.

5. **PubSub subscription timing** — The editor subscribes to `workflow_run:{run_id}` after the run starts. If the run completes very quickly, early events (`:step_started`, etc.) may be missed.

## Relevant Files

- `lib/fizz_web/live/workflows_live/editor.ex` — `run_test/1` (line 561), `start_editor_test_run/2` (line 582)
- `lib/fizz/workflows.ex` — `start_run/4`
- `lib/fizz/workflows/compiler.ex` — Draft compilation

## Steps to Reproduce

1. Open a workflow with at least one trigger and one action step
2. Click "Run Test" in the editor toolbar
3. Nothing happens, or execution never progresses past "pending"

## Expected Behavior

Clicking "Run Test" should compile the current draft, start an execution, and show real-time step execution progress in the ExecutionTracePanel.

## Acceptance Criteria

- [ ] "Run Test" successfully starts a workflow execution
- [ ] Compilation errors are displayed clearly before execution is attempted
- [ ] Execution progress (step started/completed/failed) is shown in real-time
- [ ] Execution errors display meaningful context for debugging
- [ ] The "cancel execution" button works to stop a running execution
