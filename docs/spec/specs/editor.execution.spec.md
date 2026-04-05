# Editor Execution & Debugging

The editor surfaces workflow execution state in real-time via PubSub event streaming. Users can trigger test runs, run individual steps, inspect I/O data, and debug historical runs without leaving the editor.

~~~spec-meta
id: editor.execution
kind: workflow
status: active
summary: Test run lifecycle, PubSub execution event shapes, debug mode, on-demand I/O loading, single-step execution.
surface:
  - lib/fizz_web/live/workflow_editor_live.ex
  - lib/fizz/workflows/runner/worker.ex
  - assets/vue/components/workflow/ExecutionOverlay.vue
  - assets/vue/components/workflow/ExecutionTracePanel.vue
~~~

## Requirements

~~~spec-requirements
- id: editor.execution.req_test_run_compile_draft
  statement: Test runs compile the current draft in-memory via `Compiler.compile/1` without publishing. The compiler works on any `WorkflowDefinitionVersion` regardless of status.
  priority: must
  stability: stable

- id: editor.execution.req_test_run_tagged
  statement: Test runs started from the editor are tagged with `triggered_by.kind = "editor_test"` and the initiating user's ID to distinguish them from production runs.
  priority: must
  stability: stable

- id: editor.execution.req_persist_before_test_run
  statement: Before starting a test run, the LiveView calls `DraftSession.persist_now/1` to ensure the database reflects current state.
  priority: must
  stability: stable

- id: editor.execution.req_single_active_test_run
  statement: The editor tracks at most one active execution at a time. Starting a new test run while one is running cancels the previous one.
  priority: must
  stability: stable

- id: editor.execution.req_run_node_pinned_input
  statement: "Run Node (single step execution) uses pinned outputs from upstream steps as input context. If no pinned output exists for a required upstream step, the operation returns an error."
  priority: must
  stability: stable

- id: editor.execution.req_pubsub_step_events
  statement: "The Worker GenServer broadcasts step-level events on `\"workflow_run:#{run_id}\"`: `{:step_queued, payload}`, `{:step_started, payload}`, `{:step_completed, payload}`, `{:step_failed, payload}`, `{:step_skipped, payload}`."
  priority: must
  stability: stable

- id: editor.execution.req_pubsub_run_events
  statement: "The Worker broadcasts run-level events: `{:run_status_changed, %{run_id, status, timestamp}}` where status is one of `:running`, `:completed`, `:failed`, `:cancelled`, `:sleeping`."
  priority: must
  stability: stable

- id: editor.execution.req_pubsub_fanout_events
  statement: "For fan-out steps, the Worker broadcasts `{:fan_out_started, payload}`, `{:fan_out_item_completed, payload}`, and `{:fan_out_completed, payload}` with item counts and per-item status."
  priority: must
  stability: stable

- id: editor.execution.req_step_completed_payload
  statement: "The `step_completed` event payload includes: `run_id`, `step_id`, `attempt`, `output` (full data), `output_summary` (truncated for canvas), `duration_us`, and `completed_at`."
  priority: must
  stability: stable

- id: editor.execution.req_io_on_demand
  statement: Full step `input_data` and `output_data` are not pushed in the `step_executions` assign. They are loaded on-demand when the user opens the config modal for a specific step, via a `load_step_io` event.
  priority: must
  stability: stable

- id: editor.execution.req_unsubscribe_on_terminal
  statement: The LiveView unsubscribes from the run's PubSub topic when the run reaches a terminal status (completed, failed, cancelled).
  priority: must
  stability: stable

- id: editor.execution.req_debug_mode
  statement: "The `:debug` live_action (route `/projects/:project_id/workflows/:definition_id/edit/runs/:run_id`) loads a historical or in-progress run, subscribes to its PubSub topic, and displays execution data on the canvas. The draft remains editable."
  priority: must
  stability: stable

- id: editor.execution.req_compilation_error_display
  statement: If compilation fails before a test run, the compilation errors are pushed to the Vue client for display. The run is not started.
  priority: must
  stability: stable
~~~

## Scenarios

~~~spec-scenarios
- id: editor.execution.scenario_test_run_lifecycle
  given:
    - A user has a valid draft open in the editor
  when:
    - The user clicks "Run Test"
  then:
    - DraftSession persists the current state
    - The draft is compiled in-memory
    - A workflow run is started with `triggered_by.kind = "editor_test"`
    - The LiveView subscribes to `"workflow_run:#{run_id}"`
    - Step events stream to the canvas as they occur
    - On terminal status, the LiveView unsubscribes
  covers:
    - editor.execution.req_persist_before_test_run
    - editor.execution.req_test_run_compile_draft
    - editor.execution.req_test_run_tagged
    - editor.execution.req_unsubscribe_on_terminal

- id: editor.execution.scenario_run_node_no_pinned
  given:
    - Step S2 depends on output from step S1
    - No pinned output exists for S1
  when:
    - The user triggers "Run Node" on S2
  then:
    - An error is returned indicating pinned output from S1 is required
    - No execution is started
  covers:
    - editor.execution.req_run_node_pinned_input
~~~

## Verification

~~~spec-verification
- kind: source_file
  target: lib/fizz/workflows/runner/worker.ex
  covers:
    - editor.execution.req_pubsub_step_events
    - editor.execution.req_pubsub_run_events
    - editor.execution.req_pubsub_fanout_events
    - editor.execution.req_step_completed_payload

- kind: source_file
  target: lib/fizz_web/live/workflow_editor_live.ex
  covers:
    - editor.execution.req_test_run_compile_draft
    - editor.execution.req_persist_before_test_run
    - editor.execution.req_single_active_test_run
    - editor.execution.req_io_on_demand
    - editor.execution.req_debug_mode
    - editor.execution.req_unsubscribe_on_terminal
~~~
