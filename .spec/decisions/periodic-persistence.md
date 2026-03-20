# Periodic Persistence over Per-Keystroke Saves

~~~decision-meta
id: decision.periodic_persistence
date: 2026-03
status: accepted
~~~

## Context

The DraftSession GenServer holds the authoritative in-memory draft state. Every user operation mutates this in-memory state immediately. The question is when and how often to persist to Postgres.

## Decision

The DraftSession persists to the database on a periodic timer (every 5 seconds when dirty), on explicit user save (Cmd+S), before publish, before shutdown, and when the last user disconnects — but never on individual operations.

## Rationale

**Per-keystroke persistence rejected:** Each user action (typing in a field, moving a step) would generate a database write. With multiple concurrent users and high-frequency operations (drag, config editing), this produces hundreds of writes per minute. The in-memory GenServer already holds authoritative state, so the DB write is purely for durability, not consistency.

**5-second periodic timer chosen because:**
- Bounds data loss to at most 5 seconds of work in a crash scenario
- Batches many operations into a single `save_draft/3` call (full-document replacement), reducing DB load by 10-100x compared to per-operation writes
- The `dirty?` flag prevents unnecessary writes when no changes have occurred
- Explicit save (Cmd+S) provides a user-controlled durability checkpoint when needed
- Before-shutdown and before-publish persistence ensures no data is lost at critical boundaries

## Consequences

- In a DraftSession crash, up to 5 seconds of edits may be lost. The GenServer is supervised (:one_for_one) so it restarts, but reloads from the last persisted state.
- The `save_draft/3` call does full-document replacement, which is simple but means Tier 2 changeset validation runs on every persist cycle. This is acceptable because the validation is fast on typical workflow sizes.
- Users see "Unsaved changes" status briefly between operations and the next persist tick. The UI must communicate this clearly via the save status indicator.
