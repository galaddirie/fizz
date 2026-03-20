# 3. Canvas UX

## Context

The POC uses `@vue-flow/core` with custom node/edge components. The canvas interaction composables are well-structured. This document defines the production canvas UX, identifying what to keep, what to change, and what to add.

---

## Canvas Engine

**Keep `@vue-flow/core`** — mature, well-maintained, handles virtualization, pan/zoom, minimap, controls, snapping, multi-select out of the box.

**Existing packages (keep all):**
- `@vue-flow/core` — main canvas
- `@vue-flow/background` — grid background
- `@vue-flow/controls` — zoom/fit controls
- `@vue-flow/minimap` — navigation minimap

---

## Node Types

### Step Node (`Node.vue` — exists, needs updates)

The current `Node.vue` is comprehensive. Changes needed:

**Visual differentiation by step_kind:**
- `trigger` steps: distinct top border/badge color, lightning icon prefix. Triggers are regular steps filtered by `step_kind === 'trigger'` — no separate `triggers` array
- `action` steps: current default style
- `transform` steps: slightly different accent (data-oriented icon)
- `control_flow` steps: conditional/branching visual treatment

**Status indicators (exists, keep):**
- Status dot: pending (gray), queued (blue), running (animated blue), completed (green), failed (red), skipped (muted), cancelled (gray)
- Duration badge on completed steps
- Item count badge for fan-out steps
- Retry attempt indicator

**Collaboration indicators (exists, keep):**
- `selected_by` avatars (colored dots with initials)
- `locked_by` indicator (future)

**Interactions (exists, keep):**
- Double-click to inline-edit name
- Click to select, Shift+click to multi-select
- Right-click for context menu
- Output handle quick-add button (opens AddStepPicker)
- Drag to move (with snap-to-grid)

### SubNode (`SubNode.vue` — exists, keep)

Smaller footprint, attached to parent step's subnode slots. Same status overlay. No subnode slots of their own.

### Group Node (`GroupNode.vue` — exists, needs minor update)

**Remove `output_step_id`** — the backend `StepGroup` doesn't have it. Otherwise keep:
- Container with header (name, color, collapse toggle)
- Resizable borders
- Drag moves all contained steps
- Collapse hides step details, shows summary
- Inline name editing with font size adjustment
- Custom color via hex picker

### Connection Validation

When creating edges, validate:
- **No self-connections:** source !== target
- **No duplicates:** connection between same source_output → target_input doesn't already exist
- **Subnode connections:** only to valid slot types (check `StepType.subnode_slots[].accepts.type_ids`)
- **Trigger constraint:** trigger steps must be roots (no incoming connections)
- **Cycle detection:** lightweight client-side check using topological sort from `useWorkflowGraph`. Server also validates on operation apply.

---

## Interactions

### Drag & Drop (exists, keep)

**From NodeLibrary:** Drag step type from sidebar onto canvas → emits `add_step` with position.

**Node drag:** `useNodeDrag` handles single/multi-node drag with:
- Snap-to-grid (24px, togglable via toolbar or Cmd modifier)
- Group containment (steps dragged into group bounds join the group)
- Collaboration: emits drag position for other users' ghost display
- Commit on drag-end via `commit_drag_layout` operation

### Multi-Select (exists, keep)

- Shift/Meta/Ctrl + click for additive selection
- Rubber-band (marquee) selection by dragging on empty canvas
- Cmd+A to select all
- Operations on selection: move, delete, duplicate, group, copy

### Keyboard Shortcuts (exists, keep)

| Shortcut | Action |
|----------|--------|
| `Delete` / `Backspace` | Remove selected steps/connections |
| `Cmd+Z` | Undo |
| `Cmd+Shift+Z` | Redo |
| `Cmd+C` | Copy selection |
| `Cmd+X` | Cut selection |
| `Cmd+V` | Paste |
| `Cmd+D` | Duplicate selection |
| `Cmd+G` | Group selected steps |
| `Cmd+Shift+G` | Ungroup |
| `Cmd+S` | Save |
| `Cmd+Shift+P` | Publish |
| `Escape` | Deselect / close modals |

### Context Menu (exists, keep)

**Node context menu:**
- Edit configuration
- Duplicate
- Run this step
- Add to group / Remove from group
- Pin output / Unpin
- Disable / Enable
- Delete

**Canvas context menu:**
- Add step (opens AddStepPicker)
- Paste
- Select all
- Tidy layout
- Fit view

### Auto-Layout (exists, keep)

`useLayoutEngine` provides automatic graph layout. Triggered by:
- "Tidy Layout" button in toolbar/context menu
- Produces `tidy_layout` operation with new positions for all steps and groups
- Uses dagre or similar layered graph layout algorithm

---

## Performance at Scale

### Vue Flow Virtualization

Vue Flow virtualizes off-screen nodes automatically. For 100+ step workflows:
- Only visible nodes render DOM elements
- Minimap renders simplified representations
- Edge rendering is optimized for visible viewport

### Additional Optimizations

- **Lazy config schema loading:** Don't push full `config_schema` for all step types in the initial props. Push a summary (`node_library_items`) for the sidebar, load full schema on demand when config modal opens.
- **Group collapse:** Collapsed groups reduce visible node count. Large workflows should default to collapsed groups.
- **Batch prop updates:** When DraftSession broadcasts changes, the LiveView batches updates into a single assign push (LiveView already does this within a single `handle_info`).
- **Debounced drag:** Position updates during drag are optimistic/local. Only `commit_drag_layout` on drag-end sends to server.

### Measured Targets

| Metric | Target |
|--------|--------|
| Canvas render (50 steps) | < 16ms (60fps) |
| Canvas render (200 steps) | < 33ms (30fps) |
| Node drag (smooth) | No frame drops |
| Add step response | < 100ms perceived |
| Canvas zoom/pan | Native smooth |

---

## Layout Constants

Keep existing constants from `assets/vue/constants/layout.ts`:
- Grid size: 24px
- Default viewport: zoom 1.2, offset (100, 50)
- Node dimensions: 150x50 (steps), 360x240 (groups), 112x96 (subnodes)
- Group content insets: 24px left/right, 64px top, 52px bottom

---

## What Exists vs. What's New

**Exists (keep as-is):**
- `WorkflowCanvas.vue` — Vue Flow wrapper with background, controls, minimap
- `Node.vue` — step node renderer with all status/collaboration indicators
- `SubNode.vue` — subnode renderer
- `GroupNode.vue` — group container (minor update: remove output_step_id)
- `Edge.vue` — custom bezier edge with gradient/stats
- `Handle.vue` — connection handles with quick-add
- `EditorToolbar.vue` — undo/redo/save toolbar
- `AddStepPicker.vue` — quick-add step search modal
- `NodeLibrary.vue` — sidebar step type browser
- `CollaborativeCursors.vue` — multi-user cursor overlay
- `ExecutionOverlay.vue` — execution status bar
- All composables: `useWorkflowEditor`, `useCanvasInteraction`, `useNodeInteraction`, `useNodeDrag`, `useEdgeInteraction`, `useGrouping`, `useClipboard`, `useKeyboardShortcuts`, `useLayoutEngine`, `useContextMenu`, `useDraftSync`, `useMiniMapNodeColor`
- All geometry utilities: `workflowGeometry.ts`
- Color utilities: `color.ts`
- Layout constants: `layout.ts`

**Needs updates:**
- `Node.vue` — visual differentiation by `step_kind` for trigger/transform/control_flow
- `GroupNode.vue` — remove `output_step_id` reference
- `useWorkflowNodes` — update to read from `props.draft.steps` instead of `props.workflow.draft.steps`
- `useWorkflowEdges` — same data path update
- `useEdgeInteraction` — add connection validation (cycle check, subnode slot type check, trigger root constraint)
- All composables referencing POC types — update to new TypeScript interfaces

**New:**
- Nothing major. The canvas layer is the strongest part of the POC. Focus is on type alignment and data path updates.

---

## POC Mismatches to Resolve

1. **Data path:** All composables access `props.workflow.draft.*` — must change to `props.draft.*`
2. **Trigger nodes:** POC has separate `triggers` array; must filter steps by `step_kind === 'trigger'` instead
3. **Group output_step_id:** Remove from GroupNodeData and update_group emits
4. **Command emission:** POC emits to `$live.pushEvent('editor_command', ...)`. Target: same pattern, but LiveView dispatches to DraftSession instead of handling inline
5. **Pinia stores:** `undoStore` becomes a pass-through for server-managed state (no local stack computation). `clientStore` for panel state (collapse, widths) stays client-side.
