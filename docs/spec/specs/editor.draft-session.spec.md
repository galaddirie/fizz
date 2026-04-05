# Editor Draft Session

The DraftSession GenServer is the authoritative owner of in-memory draft state during editing. It serializes all structural mutations, maintains per-user undo stacks, and periodically persists to the database.

~~~spec-meta
id: editor.draft_session
kind: service
status: active
summary: DraftSession GenServer lifecycle, operation model, undo/redo, and persistence contracts.
surface:
  - lib/fizz/workflows/draft_session.ex
  - lib/fizz/workflows/draft_session/operation.ex
  - lib/fizz/workflows/draft_session_supervisor.ex
~~~

## Requirements

~~~spec-requirements
- id: editor.draft_session.req_one_per_version
  statement: At most one DraftSession GenServer exists per `version_id` at any time, registered via `DraftSessionRegistry`.
  priority: must
  stability: stable

- id: editor.draft_session.req_started_on_join
  statement: The first user to open a draft starts the DraftSession via `DraftSessionSupervisor` if none is running; subsequent users join the existing session.
  priority: must
  stability: stable

- id: editor.draft_session.req_join_returns_state
  statement: `DraftSession.join/3` returns the current `{draft, seq, undo_state}` to the joining user.
  priority: must
  stability: stable

- id: editor.draft_session.req_seq_monotonic
  statement: The collaboration sequence number (`seq`) is a monotonically increasing integer, incremented on every successfully applied structural operation.
  priority: must
  stability: stable

- id: editor.draft_session.req_operation_apply
  statement: Each structural operation is applied via `Operation.apply(draft, params)` which returns `{:ok, new_draft, inverse_op}` on success or `{:error, reason}` on failure.
  priority: must
  stability: stable

- id: editor.draft_session.req_reject_broadcast
  statement: When an operation fails validation, the DraftSession broadcasts `{:operation_rejected, user_id, reason}` without modifying state or incrementing seq.
  priority: must
  stability: stable

- id: editor.draft_session.req_success_broadcast
  statement: When an operation succeeds, the DraftSession broadcasts `{:draft_updated, seq, summary}` where summary includes the operation type and user_id.
  priority: must
  stability: stable

- id: editor.draft_session.req_undo_per_user
  statement: Each connected user has independent undo and redo stacks stored in the DraftSession. Undo reverses only the user's own operations.
  priority: must
  stability: stable

- id: editor.draft_session.req_undo_as_operation
  statement: An undo applies the inverse operation as a new structural operation through the normal apply flow (validated, seq incremented, broadcast).
  priority: must
  stability: stable

- id: editor.draft_session.req_undo_conflict_rejection
  statement: If an undo's inverse operation conflicts with current state (e.g., target entity was deleted by another user), the undo is rejected, the entry is popped from the undo stack, and `{:undo_rejected, user_id, reason}` is broadcast.
  priority: must
  stability: stable

- id: editor.draft_session.req_redo_cleared_on_new_op
  statement: When a user applies a new structural operation (not an undo/redo), that user's redo stack is cleared.
  priority: must
  stability: stable

- id: editor.draft_session.req_persist_periodic
  statement: The DraftSession persists to the database via `Workflows.save_draft/3` every 5 seconds when `dirty?` is true.
  priority: must
  stability: stable

- id: editor.draft_session.req_persist_explicit
  statement: `DraftSession.persist_now/1` triggers an immediate database persist and broadcasts `{:draft_persisted, seq}`.
  priority: must
  stability: stable

- id: editor.draft_session.req_persist_before_shutdown
  statement: The DraftSession persists any dirty state in its `terminate/2` callback before shutting down.
  priority: must
  stability: stable

- id: editor.draft_session.req_idle_shutdown
  statement: When the last user leaves, the DraftSession starts an idle timer (5 minutes). If no user rejoins before it fires, the session persists (if dirty) and terminates.
  priority: must
  stability: stable

- id: editor.draft_session.req_dirty_tracking
  statement: The DraftSession tracks `dirty?` (unsaved changes since last persist) and `last_persisted_seq` to drive save status display.
  priority: must
  stability: stable

- id: editor.draft_session.req_dynamic_supervision
  statement: DraftSession processes are started under a DynamicSupervisor with `strategy: :one_for_one` and registered in a unique Registry keyed by `version_id`.
  priority: must
  stability: stable
~~~

## Scenarios

~~~spec-scenarios
- id: editor.draft_session.scenario_first_join
  given:
    - No DraftSession exists for version_id V
  when:
    - User A calls `DraftSession.join(V, scope, user_a_id)`
  then:
    - A new DraftSession GenServer starts under DraftSessionSupervisor
    - The draft is loaded from the database
    - User A receives `{draft, 0, empty_undo_state}`
    - A periodic persist timer (5s) is started
  covers:
    - editor.draft_session.req_started_on_join
    - editor.draft_session.req_join_returns_state
    - editor.draft_session.req_persist_periodic

- id: editor.draft_session.scenario_concurrent_undo
  given:
    - User A added step S1 (undo stack: [remove S1])
    - User B deleted step S1
  when:
    - User A presses undo (which would apply `remove S1`)
  then:
    - The inverse operation `remove S1` fails validation (S1 already deleted)
    - The entry is popped from User A's undo stack
    - `{:undo_rejected, user_a_id, reason}` is broadcast
  covers:
    - editor.draft_session.req_undo_conflict_rejection

- id: editor.draft_session.scenario_idle_shutdown
  given:
    - A DraftSession has dirty state and one connected user
  when:
    - The last user calls `leave/2`
    - 5 minutes elapse with no new joins
  then:
    - The DraftSession persists to the database
    - The GenServer terminates
  covers:
    - editor.draft_session.req_idle_shutdown
    - editor.draft_session.req_persist_before_shutdown
~~~

## Verification

~~~spec-verification
- kind: source_file
  target: lib/fizz/workflows/draft_session.ex
  covers:
    - editor.draft_session.req_one_per_version
    - editor.draft_session.req_started_on_join
    - editor.draft_session.req_seq_monotonic
    - editor.draft_session.req_persist_periodic
    - editor.draft_session.req_idle_shutdown
    - editor.draft_session.req_dirty_tracking

- kind: source_file
  target: lib/fizz/workflows/draft_session/operation.ex
  covers:
    - editor.draft_session.req_operation_apply
~~~
