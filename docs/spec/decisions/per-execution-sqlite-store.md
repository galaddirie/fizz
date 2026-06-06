# Per-Execution SQLite Store

Status: accepted

## Context

The durable runtime needs a storage model that keeps replay boundaries simple,
preserves execution isolation, and avoids shared-writer coordination inside a
single workflow execution.

The planning material converges on two durable points:

- a workflow execution is the unit of durable mutable state
- the persisted checkpoint format for this store is the workflow log itself

## Decision

Each workflow execution owns its own SQLite database file.

For this store shape:

- the execution-to-database mapping is 1:1
- the canonical persisted payload is the workflow log checkpoint
- full-log checkpointing is the chosen persistence strategy for the SQLite store

## Consequences

- Execution durability stays isolated to one file per run.
- The SQLite schema remains minimal because it stores workflow checkpoints
  rather than a large shared event table.
- Global queries across executions (list runs, find by status, etc.) are served
  by the Postgres control plane, not by scanning individual SQLite files.
- Full-log checkpointing grows with history length; ContinueAsNew is the
  mitigation for long-lived runs.
- Event-sourced persistence remains a valid alternative for a different future
  store adapter, but it is not the current store contract.
- Litestream replication, S3 passivation, pruning policy, and file lifecycle
  tuning were intentionally left out because they are still implementation and
  operations detail, not core storage truth.

## Related decisions

- `postgres-control-plane.md` — the global index and coordination layer that
  complements per-execution SQLite files
- `single-writer-leasing-and-fencing.md` — the ownership model that guards
  writes to each execution store
- `continue-as-new-boundary.md` — the mechanism that bounds full-log checkpoint
  growth for long-lived runs

## Sources

- `docs/plans/durable-workflow-system-design.md`
- `docs/plans/runic-research.md`
