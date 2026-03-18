# Postgres Control Plane

Status: accepted

## Context

The per-execution SQLite store isolates durable workflow state to one file per
run, but the platform still needs a shared coordination layer for concerns that
span executions or must be accessible when a specific execution is dormant.

The design material and multiple existing decisions depend on this layer without
an explicit decision establishing it:

- global run indexing and status queries across all executions
- lease records and monotonic fence tokens for single-writer enforcement
- signal inbox acceptance and dedup while the target execution is dormant
- durable timer registration and firing
- continuation lineage linking parent and child runs

## Decision

Postgres is the control-plane store for cross-execution coordination and global
queries.

That means:

- the Postgres control plane is the authoritative home for run metadata, lease
  records, fence tokens, the signal inbox, durable timer registrations, and
  continuation lineage
- per-execution SQLite files remain the authoritative store for workflow history
  and checkpoint state within a single run
- the control plane does not store or replicate workflow checkpoint payloads

## Consequences

- Global queries (list runs, filter by status, search by definition) are served
  from Postgres without scanning individual SQLite files.
- Fence token validation at the SQLite commit boundary reads the authoritative
  token from Postgres, preventing stale owners from self-validating.
- Signals can be accepted and deduplicated even when the target execution's
  SQLite file is not open.
- Durable timers are registered in Postgres and fire through the platform's
  scheduling infrastructure rather than relying on in-memory process timers.
- The control plane schema and the per-execution SQLite schema evolve
  independently.
- Exact table schemas, index strategies, and Oban integration details are
  implementation planning detail and are not part of this decision.

## Related decisions

- `per-execution-sqlite-store.md` — the execution-scoped store that this control
  plane complements
- `single-writer-leasing-and-fencing.md` — the ownership model whose lease and
  fence records live here
- `signal-dedup-scope.md` — the signal inbox whose durable home is here
- `continue-as-new-boundary.md` — the continuation lineage metadata stored here
- `durable-timer-model.md` — the timer contract whose durable rows live here

## Sources

- `docs/plans/durable-workflow-system-design.md`
