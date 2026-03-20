# Editor State Model

The workflow editor manages four distinct state categories with clear ownership boundaries. Correct behavior depends on each category being mutated only by its designated owner and stored in the correct medium.

~~~spec-meta
id: editor.state_model
kind: component
status: active
summary: State taxonomy, ownership boundaries, and LiveView assigns contract for the workflow editor.
surface:
  - lib/fizz_web/live/workflow_editor_live.ex
  - lib/fizz/workflows/draft_session.ex
  - assets/vue/WorkflowEditor.vue
~~~

## Requirements

~~~spec-requirements
- id: editor.state_model.req_four_categories
  statement: Editor state is partitioned into exactly four categories — authored, published artifacts, runtime execution, and ephemeral collaboration — each with a single owner.
  priority: must
  stability: stable

- id: editor.state_model.req_authored_owner
  statement: Authored state (steps, connections, step_groups, viewport, settings, step positions, notes, colors) is owned by the Workflows context and stored in Postgres via `workflow_definition_versions`.
  priority: must
  stability: stable

- id: editor.state_model.req_authored_mutability
  statement: Authored state is mutable while the version status is `draft` and immutable once `published`.
  priority: must
  stability: stable

- id: editor.state_model.req_published_immutable
  statement: Published artifacts (compiled `Runic.Workflow` and `compiled_hash`) are immutable once created.
  priority: must
  stability: stable

- id: editor.state_model.req_runtime_append_only
  statement: Runtime execution state (workflow runs, step executions) is append-only; existing event log entries are never mutated.
  priority: must
  stability: stable

- id: editor.state_model.req_ephemeral_volatile
  statement: Ephemeral collaboration state (cursors, selections, drag previews) is held in-memory only (DraftSession GenServer + Phoenix Presence) and never persisted to the database.
  priority: must
  stability: stable

- id: editor.state_model.req_ui_metadata_boundary
  statement: UI metadata (positions, viewport, step_groups, notes, colors) is authored state that persists in the version snapshot but is stripped by the compiler's Normalizer before hashing.
  priority: must
  stability: stable

- id: editor.state_model.req_liveview_relay
  statement: The LiveView (`WorkflowEditorLive`) never mutates draft state directly; all structural mutations go through `DraftSession.apply_operation/3`.
  priority: must
  stability: stable

- id: editor.state_model.req_presence_bypass
  statement: Presence updates (cursor position, selection, drag state) bypass the DraftSession and go through `Presence.update/4` directly from the LiveView.
  priority: must
  stability: stable

- id: editor.state_model.req_authenticated_route
  statement: The editor LiveView is placed inside the `:require_authenticated_user` live_session and requires a `current_scope` assign.
  priority: must
  stability: stable
~~~

## Scenarios

~~~spec-scenarios
- id: editor.state_model.scenario_ui_change_no_hash
  given:
    - A draft version with a known compiled_hash
  when:
    - A user moves steps, renames groups, or changes viewport
  then:
    - The authored state (version snapshot) is updated
    - The compiled_hash remains unchanged after recompilation
  covers:
    - editor.state_model.req_ui_metadata_boundary

- id: editor.state_model.scenario_collab_state_not_persisted
  given:
    - Two users are collaborating on a draft
    - User A has cursor at position (100, 200)
  when:
    - The DraftSession persists to the database
  then:
    - No cursor, selection, or drag state is written to the database
  covers:
    - editor.state_model.req_ephemeral_volatile
~~~

## Verification

~~~spec-verification
- kind: source_file
  target: lib/fizz/workflows/compiler/normalizer.ex
  covers:
    - editor.state_model.req_ui_metadata_boundary

- kind: source_file
  target: lib/fizz_web/live/workflow_editor_live.ex
  covers:
    - editor.state_model.req_liveview_relay
    - editor.state_model.req_presence_bypass
    - editor.state_model.req_authenticated_route
~~~
