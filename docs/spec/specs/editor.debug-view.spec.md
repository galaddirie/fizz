# Editor Debug View & Version-Pinned Replay

The debug view renders a historical or in-progress workflow run on the canvas using the **exact version snapshot that was executed**, not the current draft. This ensures step execution overlays always align with the graph that produced them, even when the draft has diverged significantly.

~~~spec-meta
id: editor.debug_view
kind: workflow
status: active
summary: Version-pinned debug rendering, read-only canvas, drift detection, run-to-version navigation, and replay UX for historical and in-progress runs.
surface:
  - lib/fizz_web/live/workflows_live/editor.ex
  - lib/fizz/workflows.ex
  - assets/vue/WorkflowEditor.vue
  - assets/vue/composables/workflow/useWorkflowEditor.ts
  - assets/vue/composables/useWorkflowGraph.ts
  - assets/vue/components/flow/ExecutionTracePanel.vue
~~~

## Requirements

~~~spec-requirements
- id: editor.debug_view.req_version_pinned_graph
  statement: "In `:debug` mode, the canvas renders the graph from the `WorkflowDefinitionVersion` associated with the run (`run.workflow_definition_version_id`), not the current draft. Steps, connections, step_groups, viewport, and settings all come from the executed version snapshot."
  priority: must
  stability: stable

- id: editor.debug_view.req_read_only_canvas
  statement: "In `:debug` mode, the canvas is read-only. Structural mutations (add/remove/move steps, add/remove connections, edit step configs) are disabled. The user can pan, zoom, select steps to inspect I/O, and interact with the execution trace panel."
  priority: must
  stability: stable

- id: editor.debug_view.req_no_draft_session_join
  statement: "In `:debug` mode, the LiveView does not join the DraftSession. No collaboration state, undo history, or persistence callbacks are established. This avoids write contention and stale-draft confusion."
  priority: must
  stability: stable

- id: editor.debug_view.req_drift_detection
  statement: "When the executed version's `compiled_hash` differs from the current draft's `compiled_hash` (or the latest published version's hash), the debug view displays a drift indicator showing the version number that ran and a message that the current definition has diverged."
  priority: must
  stability: stable

- id: editor.debug_view.req_version_navigation
  statement: "The debug view provides navigation links: (1) 'View Current Draft' navigates to the edit route for the same definition, (2) 'View All Runs for This Version' filters the runs list to runs that used the same `workflow_definition_version_id`."
  priority: should
  stability: stable

- id: editor.debug_view.req_run_version_preload
  statement: "When loading a run for debug mode, the LiveView preloads `run.workflow_definition_version` with its embedded `steps`, `connections`, and `step_groups`. This version is used as the graph source."
  priority: must
  stability: stable

- id: editor.debug_view.req_live_subscription
  statement: "For non-terminal runs, the debug view subscribes to `\"workflow_run:#{run_id}\"` PubSub topic and streams step events in real-time. For terminal runs, all data is loaded from the event log without subscribing."
  priority: must
  stability: stable

- id: editor.debug_view.req_test_run_debug
  statement: "Test runs (triggered_by.kind = \"editor_test\") execute against an unpublished draft. Since the draft version is stored as the run's `workflow_definition_version_id`, the debug view renders the draft snapshot that was persisted before the test run started, preserving the version-pinned contract."
  priority: must
  stability: stable

- id: editor.debug_view.req_step_mapping_integrity
  statement: "Step execution overlays are matched to canvas nodes by `step_id`. Because the graph comes from the same version that produced the executions, every `step_id` in the execution log has a corresponding node on the canvas. No orphan overlays or phantom nodes are possible."
  priority: must
  stability: stable

- id: editor.debug_view.req_debug_mode_prop
  statement: "The LiveView passes a `debug_mode` boolean prop (or equivalent) to the Vue component. When true, the Vue editor disables all mutation controls (toolbar add actions, drag-to-connect, context menu edit/delete, step config save buttons) while keeping inspection controls active."
  priority: must
  stability: stable
~~~

## Scenarios

~~~spec-scenarios
- id: editor.debug_view.scenario_completed_run_version_pinned
  given:
    - Workflow Definition D has Version 3 (published) and Version 4 (draft)
    - Run R executed against Version 3
    - Version 4 has added new steps and removed one step that exists in Version 3
  when:
    - The user navigates to `/projects/:pid/workflows/:did/edit/runs/:rid`
  then:
    - The canvas renders Version 3's steps, connections, and groups
    - Step execution overlays align with Version 3's nodes
    - The removed step (present in V3, absent in V4) appears on the canvas with its execution data
    - The new steps (present in V4, absent in V3) do not appear on the canvas
    - A drift indicator shows "Ran on Version 3 — current draft has diverged"
  covers:
    - editor.debug_view.req_version_pinned_graph
    - editor.debug_view.req_drift_detection
    - editor.debug_view.req_step_mapping_integrity

- id: editor.debug_view.scenario_read_only_prevents_mutation
  given:
    - The user is viewing a debug run
  when:
    - The user attempts to drag a step, delete a connection, or edit step config
  then:
    - The action is blocked by the Vue editor
    - No DraftSession operation is emitted
    - Inspection actions (click to view I/O, open trace panel, pan/zoom) still work
  covers:
    - editor.debug_view.req_read_only_canvas
    - editor.debug_view.req_no_draft_session_join
    - editor.debug_view.req_debug_mode_prop

- id: editor.debug_view.scenario_in_progress_run_streams
  given:
    - Run R is currently in RUNNING status
    - Three of five steps have completed
  when:
    - The user opens the debug view for Run R
  then:
    - The three completed steps show with execution data from the event log
    - The LiveView subscribes to the run's PubSub topic
    - When step 4 completes, the overlay updates in real-time
    - When the run reaches a terminal status, the LiveView unsubscribes
  covers:
    - editor.debug_view.req_live_subscription
    - editor.debug_view.req_version_pinned_graph

- id: editor.debug_view.scenario_test_run_debug
  given:
    - The user triggers a test run from the editor
    - The current draft (Version 4, status: draft) is persisted and compiled
  when:
    - The test run starts and the user enters debug mode (or is already in it)
  then:
    - The run's `workflow_definition_version_id` points to Version 4
    - The debug canvas renders Version 4's graph
    - Execution overlays map correctly to the draft's steps
  covers:
    - editor.debug_view.req_test_run_debug
    - editor.debug_view.req_step_mapping_integrity

- id: editor.debug_view.scenario_navigate_to_draft
  given:
    - The user is in debug mode viewing a run against Version 3
    - The current draft is Version 5
  when:
    - The user clicks "View Current Draft"
  then:
    - The user is navigated to the edit route (`:edit` action) for the definition
    - The canvas shows the current draft (Version 5)
    - The DraftSession is joined normally
  covers:
    - editor.debug_view.req_version_navigation
~~~

## Verification

~~~spec-verification
- kind: source_file
  target: lib/fizz_web/live/workflows_live/editor.ex
  covers:
    - editor.debug_view.req_version_pinned_graph
    - editor.debug_view.req_read_only_canvas
    - editor.debug_view.req_no_draft_session_join
    - editor.debug_view.req_drift_detection
    - editor.debug_view.req_run_version_preload
    - editor.debug_view.req_live_subscription
    - editor.debug_view.req_debug_mode_prop

- kind: source_file
  target: lib/fizz/workflows.ex
  covers:
    - editor.debug_view.req_run_version_preload

- kind: source_file
  target: assets/vue/WorkflowEditor.vue
  covers:
    - editor.debug_view.req_read_only_canvas
    - editor.debug_view.req_debug_mode_prop
    - editor.debug_view.req_drift_detection
    - editor.debug_view.req_version_navigation

- kind: source_file
  target: assets/vue/composables/useWorkflowGraph.ts
  covers:
    - editor.debug_view.req_version_pinned_graph
    - editor.debug_view.req_step_mapping_integrity
~~~
