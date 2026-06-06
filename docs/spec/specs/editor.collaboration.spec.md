# Editor Collaboration

Concurrent editing by team-sized groups (2-10 users) on a shared draft. Operations are applied optimistically on the client and authoritatively on the server, with last-writer-wins conflict resolution at the operation level.

~~~spec-meta
id: editor.collaboration
kind: workflow
status: active
summary: Concurrency semantics, conflict resolution, presence metadata, and PubSub topic contracts.
surface:
  - lib/fizz/workflows/draft_session.ex
  - lib/fizz_web/live/workflow_editor_live.ex
  - lib/fizz_web/presence.ex
~~~

## Requirements

~~~spec-requirements
- id: editor.collab.req_optimistic_apply
  statement: The Vue client applies structural changes optimistically for immediate visual feedback. The server is authoritative; on the next prop push from the LiveView, the client reconciles its state with the server's version.
  priority: must
  stability: stable

- id: editor.collab.req_lww_per_operation
  statement: Concurrent operations on different entities both succeed. Concurrent operations on the same entity are applied sequentially in arrival order with last-writer-wins per field.
  priority: must
  stability: stable

- id: editor.collab.req_stale_op_rejection
  statement: If an operation references an entity that no longer exists (e.g., connecting to a deleted step), the operation is rejected via the normal rejection broadcast.
  priority: must
  stability: stable

- id: editor.collab.req_soft_locking
  statement: There are no hard locks on steps. Each user's selections are broadcast via Presence. Other users see visual indicators (colored borders, avatar badges) but are not blocked from editing the same step.
  priority: must
  stability: stable

- id: editor.collab.req_presence_topic
  statement: Presence is tracked on the topic `"draft:#{version_id}"`.
  priority: must
  stability: stable

- id: editor.collab.req_presence_meta
  statement: Each user's Presence metadata includes `user_id`, `user_name`, `user_email`, `cursor` (nullable xy), `selected_steps`, `focused_step` (nullable), `dragging_steps` (nullable map of step_id to position), and `dragging_groups` (nullable map of group_id to bounds).
  priority: must
  stability: stable

- id: editor.collab.req_cursor_throttle
  statement: The LiveView throttles Presence updates for cursor and drag positions to approximately 60ms intervals.
  priority: should
  stability: stable

- id: editor.collab.req_pubsub_draft_topic
  statement: The PubSub topic `"draft:#{version_id}"` carries messages `{:draft_updated, seq, summary}`, `{:draft_persisted, seq}`, `{:operation_rejected, user_id, reason}`, and `{:undo_rejected, user_id, reason}`.
  priority: must
  stability: stable

- id: editor.collab.req_pubsub_run_topic
  statement: The PubSub topic `"workflow_run:#{run_id}"` carries step-level execution events (defined in `editor.execution`).
  priority: must
  stability: stable

- id: editor.collab.req_expression_not_realtime
  statement: Expression fields are not collaboratively edited in real-time. If two users edit the same expression field simultaneously, last-writer-wins applies to the whole field value, not character-by-character.
  priority: must
  stability: stable
~~~

## Scenarios

~~~spec-scenarios
- id: editor.collab.scenario_different_entities
  given:
    - Users A and B are both connected to the same draft
  when:
    - User A moves step S1 and User B moves step S2 concurrently
  then:
    - Both operations succeed
    - Both users see both moves after reconciliation
  covers:
    - editor.collab.req_lww_per_operation

- id: editor.collab.scenario_deleted_entity_conflict
  given:
    - User A and User B are connected to the same draft containing step S1
  when:
    - User A deletes step S1
    - User B (unaware of deletion) attempts to connect to step S1
  then:
    - User A's delete succeeds
    - User B's connection operation is rejected (step not found)
    - User B sees the connection disappear on reconciliation
  covers:
    - editor.collab.req_stale_op_rejection
    - editor.collab.req_optimistic_apply
~~~

## Verification

~~~spec-verification
- kind: source_file
  target: lib/fizz/workflows/draft_session.ex
  covers:
    - editor.collab.req_lww_per_operation
    - editor.collab.req_stale_op_rejection
    - editor.collab.req_pubsub_draft_topic

- kind: source_file
  target: lib/fizz_web/live/workflow_editor_live.ex
  covers:
    - editor.collab.req_presence_topic
    - editor.collab.req_cursor_throttle
~~~
