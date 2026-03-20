# 1. Editor Architecture

## Context

The backend data model, compilation pipeline, and execution runtime are built. The Vue POC has a working component tree but uses incorrect data contracts and has no LiveView host module. This document defines the target architecture across all layers.

---

## State Taxonomy

Four distinct state categories, each with a clear owner:

| Category | Owner | Storage | Mutability |
|----------|-------|---------|------------|
| **Authored state** | `Fizz.Workflows` context | Postgres (`workflow_definition_versions`) | Mutable while draft; immutable once published |
| **Published artifacts** | `Fizz.Workflows.Compiler` | Postgres (`compiled_hash`) + compiled `Runic.Workflow` | Immutable |
| **Runtime execution state** | `Fizz.Workflows.Runner.Worker` | Postgres (`workflow_runs`) + per-run SQLite | Append-only (event log) |
| **Ephemeral collaboration state** | `DraftSession` GenServer + Phoenix Presence | In-memory only | Volatile |

**Boundary rule:** UI metadata (positions, viewport, step_groups, notes, colors) is authored state. It persists in the version snapshot but is stripped by the compiler's Normalizer before hashing. Collaboration state (cursors, selections, drag previews) never touches the database.

---

## LiveView Module

### `FizzWeb.WorkflowEditorLive` (new)

Single LiveView serving as the translation layer between Vue and backend services. Placed in `:require_authenticated_user` live_session.

**Routes** (inside existing `live_session :require_authenticated_user`):
```elixir
live "/projects/:project_id/workflows/:definition_id/edit", WorkflowEditorLive, :edit
live "/projects/:project_id/workflows/:definition_id/edit/runs/:run_id", WorkflowEditorLive, :debug
```

**Responsibilities:**
- Load definition + draft (via `Workflows.edit_definition/2` which returns existing draft or clones published)
- Load step types from `Fizz.Steps.list_types()`
- Join `DraftSession` GenServer (starts one if none running)
- Track Phoenix Presence on `"draft:#{version_id}"`
- Subscribe to PubSub topics: `"draft:#{version_id}"`, `"workflow_run:#{run_id}"` (when debugging)
- Handle all `editor_command` events → dispatch to DraftSession or handle locally
- Push updated assigns to Vue on draft/execution changes
- Handle expression preview requests (debounced, via `Expressions.preview/2`)
- Handle credential resolver queries

**Assigns:**
```elixir
%{
  # Core data (pushed as Vue props)
  current_scope: Scope.t(),
  definition: WorkflowDefinition.t(),
  draft: WorkflowDefinitionVersion.t(),  # the mutable draft snapshot
  step_types: [Type.t()],
  node_library_items: [map()],

  # Collaboration
  collab_seq: integer(),      # from DraftSession, monotonically increasing
  presences: [map()],         # from Phoenix Presence

  # Ephemeral editor state (not persisted to DB)
  editor_state: %{
    pinned_outputs: %{step_id => output_data},
    disabled_steps: [step_id],
    step_locks: %{step_id => user_id}
  },

  # Execution (nil unless test-running or in debug mode)
  execution: WorkflowRun.t() | nil,
  step_executions: [map()],

  # Transient
  expression_previews: %{field_key => preview_result},
  undo_state: %{canUndo: bool, canRedo: bool, undoLabel: str, redoLabel: str},
  credential_options: [map()],
  debug_execution_id: String.t() | nil
}
```

---

## Vue Component → LiveView Data Flow

```
Vue Component                    LiveView                         Backend
─────────────────────────────────────────────────────────────────────────
emit("editor_command",           handle_event("editor_command")   DraftSession.apply_operation()
  {type, payload})               ─── dispatches to ───>           ─── applies, increments seq ──>
                                                                  ─── broadcasts via PubSub ──>
                                 handle_info({:draft_updated})
<── receives new props ────────  push updated assigns
```

**Key principle:** The LiveView never mutates draft state directly. All mutations go through `DraftSession.apply_operation/3`, which maintains the authoritative state, undo stacks, and collaboration sequence. The LiveView is purely a relay.

**Exception:** Presence updates (cursor, selection) bypass DraftSession — they go through `Presence.update/4` directly from the LiveView since they're ephemeral and high-frequency.

---

## TypeScript Type Alignment

The POC types must be realigned to match the real backend model. Key changes:

| POC Type | Issue | Target |
|----------|-------|--------|
| `Workflow.status: 'draft' \| 'active' \| 'archived'` | Backend has `archived_at` timestamp, no "active" | `WorkflowDefinition` with `archived_at?: string` |
| `Workflow.public`, `Workflow.user_id` | Don't exist on backend | Remove; use `project_id`, `created_by_user_id` |
| `Workflow.current_version_tag` | Backend uses integer `version` | `latest_version: number` |
| `WorkflowDraft` as separate entity | Backend: `WorkflowDefinitionVersion` IS the draft | Flatten: `draft` prop is the version with embedded steps |
| `WorkflowDraft.triggers` (separate array) | Backend: triggers are steps with `kind: :trigger` | Remove `triggers` array; filter `steps` by `step_kind` |
| `NodeGroup.output_step_id` | Not in backend `StepGroup` | Remove |
| `WorkflowVersion.version_tag`, `changelog` | Backend: integer `version`, no changelog | Replace with `version: number` |
| `Execution.execution_type` | Backend `WorkflowRun` has no such field | Remove |

**New TypeScript interfaces** (replacing POC types):
```typescript
interface WorkflowDefinition {
  id: string;
  project_id: string;
  name: string;
  description?: string;
  created_by_user_id: string;
  archived_at?: string;
  inserted_at: string;
  updated_at: string;
}

interface WorkflowDefinitionVersionDraft {
  id: string;
  workflow_definition_id: string;
  version: number;
  status: 'draft' | 'published' | 'archived';
  steps: Step[];
  connections: Connection[];
  step_groups: StepGroup[];
  viewport: { x: number; y: number; zoom: number };
  settings: Record<string, unknown>;
  inserted_at: string;
  updated_at: string;
}
```

---

## Backend Contracts — New Modules

### `Fizz.Workflows.DraftSession` (GenServer)
See `02-collaboration.md` for full design. Summary:
- One per active draft, keyed by `version_id`
- Holds authoritative in-memory draft + per-user undo stacks + collab_seq
- Applies operations, validates, broadcasts
- Periodically persists to DB

### `Fizz.Workflows.DraftSession.Operation`
Structured operation module. Each operation: `apply(draft, params) → {:ok, new_draft, undo_entry} | {:error, reason}`.

### `Fizz.Workflows.validate_draft/1`
Real-time validation returning structured errors per step/field. Used for editor-time warnings.

### `Fizz.Workflows.Expressions.preview/2`
Evaluates an expression against available context, returns `{:ok, result} | {:error, message}`.

---

## What Exists vs. What's New

**Exists (keep):**
- Full data model: `workflow_definitions`, `workflow_definition_versions` with embeds, `workflow_runs`
- `Fizz.Workflows` context: `create_definition`, `save_draft`, `publish_draft`, `edit_definition`, `start_run`, `cancel_run`
- Compilation pipeline: Normalizer → ExpressionCompiler → Assembler → Hasher
- Step type registry with 50+ executors, config schemas, resolver system
- Vue component tree: WorkflowEditor, Canvas, Node, Edge, GroupNode, StepConfigModal, all field components
- ~20 composables: useWorkflowEditor, useDraftSync, useCollaboration, useNodeDrag, etc.
- Pinia stores: undoStore, clientStore, theme
- Phoenix Presence module, PubSub infrastructure

**New (build):**
- `FizzWeb.WorkflowEditorLive` — the LiveView host
- `Fizz.Workflows.DraftSession` + `DraftSessionSupervisor` — collaboration session management
- `Fizz.Workflows.DraftSession.Operation` — structured operation application
- `Fizz.Workflows.validate_draft/1` — real-time structured validation
- `Fizz.Workflows.Expressions.preview/2` — expression preview API
- Router routes for the editor
- TypeScript type realignment (update `types/workflow.ts`, `types/workflowEditor.ts`)
- `WorkflowEditorProps` interface update

---

## Critical Files

| File | Role |
|------|------|
| `lib/fizz/workflows.ex` | Context module; DraftSession integration point |
| `lib/fizz/workflows/workflow_definition_version.ex` | Schema + validation; validation tiers depend on this |
| `lib/fizz_web/router.ex` | New editor routes in `:require_authenticated_user` |
| `assets/vue/types/workflow.ts` | TypeScript types to realign |
| `assets/vue/types/workflowEditor.ts` | Editor props/commands to update |
| `assets/vue/composables/workflow/useWorkflowEditor.ts` | Main orchestrator; wires LiveVue contract |
| `assets/vue/WorkflowEditor.vue` | Top-level component; props interface |
