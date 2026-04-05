# Operation-Based Collaboration with Server Authority

~~~decision-meta
id: decision.operation_based_collaboration
date: 2026-03
status: accepted
~~~

## Context

The workflow editor needs concurrent editing by team-sized groups (2-10 users). The document is a set of discrete entities (steps, connections, groups) — not linear text. Three approaches were evaluated: OT/CRDT, pessimistic locking, and operation-based editing with server authority.

## Decision

Use operation-based editing with a server-authoritative GenServer (DraftSession). Each user action produces a typed, semantically meaningful operation (e.g., `add_step`, `move_step`, `update_step_config`). Operations are sent to a single GenServer per draft that applies them sequentially, validates each one, computes undo inverses, and broadcasts results. Clients apply changes optimistically and reconcile on the next server push.

## Rationale

**OT/CRDT rejected:** The data model consists of discrete entities, not character sequences. Operations are high-level and semantic (add/remove/update step), not character-level inserts/deletes. The number of concurrent editors is team-sized (2-10), not crowd-sized. OT/CRDT introduces significant complexity (conflict functions, vector clocks) for a problem shape that doesn't require it.

**Pessimistic locking rejected:** Step-level locks would block users constantly. Workflows have few enough steps that concurrent edits to the same step are rare, but concurrent edits to different steps are common. Locking the whole draft defeats the purpose of collaboration.

**Operation-based chosen because:**
- Matches the natural granularity of user actions (add step, move step, etc.)
- Each operation has a clear inverse, enabling per-user undo without a global undo log
- Sequential application through a single GenServer provides total ordering without coordination complexity
- Server authority means the GenServer is always consistent — no divergence to resolve
- Last-writer-wins at the operation level is intuitive and correct for team-sized collaboration

## Consequences

- The single GenServer is the throughput bottleneck. Acceptable for 2-10 users; would need partitioning for 50+ concurrent editors.
- Expression fields within steps are NOT collaboratively edited in real-time (LWW on the whole field value). Real-time text co-editing within a field would require a different approach (CRDT/OT at the text level).
- Operations from different users are serialized through the GenServer mailbox, introducing a small latency (mitigated by client-side optimistic application).
- The undo model is per-user, which means User A cannot undo User B's changes — this is intentional.
