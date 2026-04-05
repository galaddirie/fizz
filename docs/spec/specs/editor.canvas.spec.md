# Editor Canvas

The workflow canvas renders steps, connections, and groups on a pannable/zoomable surface using Vue Flow. This spec covers the validation rules, node type contracts, and interaction invariants — not the rendering implementation.

~~~spec-meta
id: editor.canvas
kind: component
status: active
summary: Connection validation rules, node type visual contracts, keyboard shortcuts, and layout constants.
surface:
  - assets/vue/components/workflow/canvas/Node.vue
  - assets/vue/components/workflow/canvas/GroupNode.vue
  - assets/vue/components/workflow/canvas/Edge.vue
  - assets/vue/composables/workflow/useEdgeInteraction.ts
  - assets/vue/constants/layout.ts
~~~

## Requirements

~~~spec-requirements
- id: editor.canvas.req_no_self_connections
  statement: A connection where source step equals target step must be rejected.
  priority: must
  stability: stable

- id: editor.canvas.req_no_duplicate_connections
  statement: A connection between the same `source_output` and `target_input` pair must be rejected if one already exists.
  priority: must
  stability: stable

- id: editor.canvas.req_trigger_root_constraint
  statement: Trigger steps (steps with `step_kind === 'trigger'`) must have no incoming connections.
  priority: must
  stability: stable

- id: editor.canvas.req_cycle_detection
  statement: Connections that would introduce a cycle in the directed graph must be rejected. Client-side performs a lightweight check; the server also validates on operation apply.
  priority: must
  stability: stable

- id: editor.canvas.req_subnode_slot_type_check
  statement: Subnode connections must only connect to valid slot types as defined by `StepType.subnode_slots[].accepts.type_ids`.
  priority: must
  stability: stable

- id: editor.canvas.req_step_kind_visual
  statement: Steps are visually differentiated by `step_kind`: trigger steps have a distinct border/badge and lightning icon; action, transform, and control_flow steps each have their own visual treatment.
  priority: should
  stability: stable

- id: editor.canvas.req_status_indicators
  statement: Each step node displays a status dot reflecting its execution state (pending, queued, running, completed, failed, skipped, cancelled) when execution data is available.
  priority: must
  stability: stable

- id: editor.canvas.req_triggers_from_steps
  statement: Triggers are regular steps filtered by `step_kind === 'trigger'`. There is no separate `triggers` array.
  priority: must
  stability: stable

- id: editor.canvas.req_group_no_output_step
  statement: The `GroupNode` does not have an `output_step_id` property. Group membership is tracked via `step_groups[].step_ids`.
  priority: must
  stability: stable

- id: editor.canvas.req_drag_commit_on_end
  statement: During drag, position updates are optimistic and local. Only `commit_drag_layout` on drag-end sends the final positions as an operation to the server.
  priority: must
  stability: stable

- id: editor.canvas.req_snap_to_grid
  statement: Node drag supports snap-to-grid at 24px intervals, togglable via the toolbar or a modifier key.
  priority: should
  stability: stable

- id: editor.canvas.req_grid_size
  statement: The canvas grid size is 24px.
  priority: must
  stability: stable

- id: editor.canvas.req_keyboard_shortcuts
  statement: The editor supports keyboard shortcuts including Delete/Backspace (remove), Cmd+Z (undo), Cmd+Shift+Z (redo), Cmd+C/X/V (copy/cut/paste), Cmd+D (duplicate), Cmd+G (group), Cmd+Shift+G (ungroup), Cmd+S (save), Cmd+Shift+P (publish), Escape (deselect/close).
  priority: must
  stability: stable
~~~

## Verification

~~~spec-verification
- kind: source_file
  target: assets/vue/composables/workflow/useEdgeInteraction.ts
  covers:
    - editor.canvas.req_no_self_connections
    - editor.canvas.req_no_duplicate_connections
    - editor.canvas.req_cycle_detection
    - editor.canvas.req_subnode_slot_type_check
    - editor.canvas.req_trigger_root_constraint

- kind: source_file
  target: assets/vue/components/workflow/canvas/Node.vue
  covers:
    - editor.canvas.req_step_kind_visual
    - editor.canvas.req_status_indicators

- kind: source_file
  target: assets/vue/constants/layout.ts
  covers:
    - editor.canvas.req_grid_size
~~~
