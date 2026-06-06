# 2. Collaboration Model

## Context

The spec marks concurrent editing as "v1 OUT-OF-SCOPE (single-user draft mode assumed)." The user wants real collaboration designed. The POC has collaboration infrastructure (Presence, cursors, selection sync, collabSeq) but no actual concurrent mutation handling. This document designs the full model.

---

## Approach: Operation-Based Editing with Server Authority

**Why not OT/CRDT:** The document is a set of discrete entities (steps, connections, groups), not linear text. Operations are high-level and semantically meaningful (add_step, move_step, update_step_config), not character-level. The number of concurrent editors is team-sized (2-10), not crowd-sized. OT/CRDT complexity is unjustified.

**Why not pessimistic locking:** Step-level locks would block users constantly. Workflows have few enough steps that concurrent edits to the _same_ step are rare but concurrent edits to _different_ steps are common. Locking the whole draft for one user defeats the purpose.

**Chosen model:** Each user action produces a typed operation sent to a server-side `DraftSession` GenServer. The server applies operations sequentially, validates each one, computes undo inverses, increments a monotonic sequence number, and broadcasts the result. Clients apply changes optimistically and reconcile on the next server push.

---

## DraftSession GenServer

### State Structure

```elixir
defmodule Fizz.Workflows.DraftSession do
  use GenServer

  defstruct [
    :version_id,
    :draft,                    # %WorkflowDefinitionVersion{} — authoritative in-memory state
    :seq,                      # monotonically increasing integer
    :undo_stacks,              # %{user_id => [{inverse_op, label, seq}]}
    :redo_stacks,              # %{user_id => [{forward_op, label, seq}]}
    :dirty?,                   # whether unsaved changes exist since last persist
    :last_persisted_seq,       # seq at last DB write
    :connected_users,          # MapSet of user_ids currently connected
    :persist_timer_ref,        # periodic persist timer
    :idle_timer_ref,           # shutdown after all users leave
    :scope                     # %Scope{} for DB operations
  ]
end
```

### Lifecycle

```
First user opens editor
  └─> LiveView calls DraftSession.join(version_id, scope, user_id)
      └─> DraftSessionSupervisor starts GenServer if not running
      └─> GenServer loads draft from DB, returns {draft, seq, undo_state}
      └─> Starts periodic persist timer (every 5s)

Subsequent users join
  └─> join/3 returns current {draft, seq, undo_state} (empty stacks for new user)
  └─> Connected users set updated

User leaves
  └─> DraftSession.leave(version_id, user_id)
  └─> If last user: start idle timer (5 minutes)

Idle timer fires
  └─> Persist if dirty, then terminate

Explicit save (Cmd+S)
  └─> DraftSession.persist_now(version_id)
  └─> Calls Workflows.save_draft/3
  └─> Broadcasts {:draft_persisted, seq}
```

### Supervision

```elixir
# In application.ex supervision tree:
{DynamicSupervisor, name: Fizz.Workflows.DraftSessionSupervisor, strategy: :one_for_one}
{Registry, keys: :unique, name: Fizz.Workflows.DraftSessionRegistry}
```

DraftSession processes are registered under `{DraftSessionRegistry, version_id}` for lookup.

---

## Operation Model

### Operation Types

Every editor action maps to a typed operation. Operations are the unit of collaboration, undo, and persistence.

```elixir
defmodule Fizz.Workflows.DraftSession.Operation do
  @type t :: %{type: atom(), params: map(), user_id: String.t()}

  # Each operation module implements:
  # apply(draft, params) -> {:ok, new_draft, inverse_op} | {:error, reason}
  #
  # The inverse_op is the operation that undoes this one.
end
```

**Structural operations:**
| Operation | Params | Inverse |
|-----------|--------|---------|
| `add_step` | `{type_id, position, config, ?group_id, ?auto_connect}` | `remove_step{step_id}` |
| `remove_step` | `{step_id}` | `add_step` with full step data + reconnect |
| `update_step` | `{step_id, changes: %{name?, config?, notes?}}` | `update_step` with old values |
| `move_step` | `{step_id, position}` | `move_step` with old position |
| `move_steps` | `{step_positions: %{id => pos}}` | `move_steps` with old positions |
| `add_connection` | `{source_step_id, target_step_id, source_output, target_input}` | `remove_connection{id}` |
| `remove_connection` | `{connection_id}` | `add_connection` with full data |
| `add_group` | `{name, step_ids, position, color}` | `remove_group{id}` |
| `update_group` | `{group_id, changes}` | `update_group` with old values |
| `remove_group` | `{group_id}` | `add_group` with full data |
| `set_group_membership` | `{step_ids, group_id}` | `set_group_membership` with old membership |
| `duplicate_steps` | `{step_ids, positions}` | `remove_steps` for new IDs |
| `commit_drag_layout` | `{txn_id, groups, step_positions, memberships}` | `commit_drag_layout` with old positions |
| `tidy_layout` | `{steps: [{id, pos}], groups: [{id, pos}]}` | `tidy_layout` with old positions |

**Editor-only operations (no undo, no persistence impact):**
| Operation | Handled by |
|-----------|-----------|
| `mouse_move` | Presence.update directly from LiveView |
| `selection_changed` | Presence.update directly from LiveView |
| `preview_expression` | LiveView handles directly, result pushed as assign |

**Execution operations:**
| Operation | Handled by |
|-----------|-----------|
| `run_test` | LiveView → Workflows.start_run |
| `run_node` | LiveView → Workflows.start_run (partial) |
| `cancel_execution` | LiveView → Workflows.cancel_run |
| `pin_output` / `unpin_output` | LiveView updates editor_state assign |
| `disable_step` / `enable_step` | LiveView updates editor_state assign |

**Workflow lifecycle operations:**
| Operation | Handled by |
|-----------|-----------|
| `save_workflow` | DraftSession.persist_now |
| `publish_workflow` | DraftSession.persist_now → Workflows.publish_draft |

### Apply Flow

```
1. LiveView receives editor_command event
2. Classifies operation:
   - Structural → DraftSession.apply_operation(version_id, user_id, op)
   - Presence → Presence.update(...)
   - Execution → Workflows.start_run/cancel_run
   - Preview → Expressions.preview(...)
3. DraftSession.apply_operation:
   a. Calls Operation.apply(draft, params)
   b. If {:ok, new_draft, inverse}:
      - draft = new_draft
      - seq += 1
      - Push inverse onto user's undo stack
      - Clear user's redo stack
      - dirty? = true
      - Broadcast {:draft_updated, seq, %{type: op_type, user_id, summary}}
   c. If {:error, reason}:
      - Broadcast {:operation_rejected, user_id, reason}
4. LiveView receives broadcast, pushes updated draft + seq + undo_state to Vue
```

---

## Concurrency Semantics

### Optimistic Application with Server Reconciliation

The Vue client applies changes optimistically to local Vue Flow state for immediate visual feedback. The server validates and applies authoritatively. If the server rejects (e.g., removing a step that was already removed), the client reconciles on the next prop push from the LiveView.

### Conflict Resolution: Last-Writer-Wins at Operation Level

- Two users move **different** steps → both succeed, no conflict
- Two users edit **same** step config → both apply sequentially in arrival order, last write wins per field
- User A removes step X while user B connects to step X → removal succeeds first; connection op fails validation (step not found); user B sees connection disappear on reconciliation
- User A undoes while user B edits the same step → undo applies as a regular operation; if the undo's inverse conflicts with current state, it's rejected

### Selection-Based Soft Locking

No hard locks. Instead:
- Each user's selections broadcast via Presence
- Other users see colored borders + avatar badges on steps selected by others
- The UI shows a warning ("Alice is also editing this step") but doesn't block
- Optional: LiveView can track `editor_state.step_locks` for explicit lock requests (future)

---

## Undo/Redo

### Per-User Stacks, Server-Managed

Each user has independent undo/redo stacks stored in the DraftSession. Undo reverses the user's own operations, not the global history.

```
User A adds step → A's undo stack: [remove_step]
User B moves step → B's undo stack: [move_step_back]
User A presses Cmd+Z → applies remove_step as a new operation
  → A's undo stack: []
  → A's redo stack: [add_step]
  → B's stacks unchanged
```

### Undo Conflict Handling

If an undo operation conflicts with current state (e.g., undoing "add connection to X" but X was deleted by another user), the DraftSession:
1. Rejects the undo
2. Pops the entry from the undo stack (it's no longer applicable)
3. Broadcasts `{:undo_rejected, user_id, reason}` so the LiveView can notify the user

### Undo State Pushed to Vue

```elixir
%{
  canUndo: length(undo_stack) > 0,
  canRedo: length(redo_stack) > 0,
  undoLabel: hd(undo_stack).label || nil,
  redoLabel: hd(redo_stack).label || nil,
  undoStack: Enum.map(undo_stack, &%{label: &1.label}),
  redoStack: Enum.map(redo_stack, &%{label: &1.label})
}
```

This matches the existing `useUndoStore` interface. The Pinia store becomes a pass-through for server state rather than managing its own stack.

---

## Persistence Strategy

DraftSession persists to DB via `Workflows.save_draft/3`:

1. **Periodic timer:** Every 5 seconds if `dirty? == true`
2. **Explicit save:** User Cmd+S or toolbar Save button → `persist_now/1`
3. **Before publish:** `persist_now/1` called before `publish_draft/2`
4. **Before shutdown:** On idle timeout or application shutdown
5. **Never on individual operations:** Each keystroke does NOT trigger a DB write

After persist: `dirty? = false`, `last_persisted_seq = seq`, broadcast `{:draft_persisted, seq}`.

The LiveView shows "Last saved: X ago" based on the draft's `updated_at` timestamp.

---

## Presence

Uses existing `FizzWeb.Presence` module. Topic: `"draft:#{version_id}"`.

**Presence meta per user:**
```elixir
%{
  user_id: String.t(),
  user_name: String.t(),
  user_email: String.t(),
  cursor: %{x: float, y: float} | nil,
  selected_steps: [step_id],
  focused_step: step_id | nil,
  dragging_steps: %{step_id => %{x: float, y: float}} | nil,
  dragging_groups: %{group_id => %{x: float, y: float, width: float, height: float}} | nil
}
```

**Update frequency:** Cursor/drag updates are high-frequency. The LiveView should throttle Presence.update to ~60ms intervals (matching the POC's `CURSOR_THROTTLE_MS`). Selection changes are event-driven (no throttle needed).

---

## PubSub Topics

| Topic | Messages | Producer | Consumer |
|-------|----------|----------|----------|
| `"draft:#{version_id}"` | `{:draft_updated, seq, summary}`, `{:draft_persisted, seq}`, `{:operation_rejected, user_id, reason}`, `{:undo_rejected, user_id, reason}` | DraftSession | WorkflowEditorLive |
| `"workflow_run:#{run_id}"` | Step-level execution events (see `05-execution.md`) | Runner.Worker | WorkflowEditorLive |

---

## What Exists vs. What's New

**Exists:**
- `FizzWeb.Presence` module
- `useCollaboration` composable (cursor throttling, selection sync, drag state)
- `CollaborativeCursors.vue` component
- `UserPresence` TypeScript interface
- `useDraftSync` composable (watches collabSeq, syncs nodes/edges)
- `useUndoStore` Pinia store (state shape matches target)
- `collabSeq` mechanism for change detection
- PubSub infrastructure

**New:**
- `Fizz.Workflows.DraftSession` GenServer
- `Fizz.Workflows.DraftSessionSupervisor` DynamicSupervisor
- `Fizz.Workflows.DraftSession.Operation` module (all operation types + inverse computation)
- `Fizz.Workflows.DraftSessionRegistry` for process lookup
- PubSub topic conventions and message shapes
- LiveView handlers for operation dispatch and broadcast handling

---

## Assumptions

1. **Team-sized concurrency:** 2-10 simultaneous editors. If this grows to 50+, the single-GenServer model needs partitioning.
2. **Single draft per definition:** Only one draft version exists at a time. Multiple "branches" are not supported.
3. **Operation ordering:** Operations from different users are serialized through the GenServer mailbox. This is acceptable at team scale but would bottleneck at crowd scale.
4. **Expression fields are NOT collaboratively edited** in real-time. If two users edit the same expression field simultaneously, last-writer-wins applies to the whole field value, not character-by-character. Real-time collaborative text editing within expression fields is deferred.

## Follow-Up Work

- Multi-cursor text editing within expression fields (would require CRDT/OT for text)
- Step-level locking (optional, explicit lock/unlock)
- Conflict resolution UI (show what changed, offer merge options)
- Offline support / reconnection handling beyond LiveView's built-in reconnect
