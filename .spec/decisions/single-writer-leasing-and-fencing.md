# Single-Writer Leasing And Fencing

Status: accepted

## Context

A durable workflow execution may move between nodes, but its apply and durable
commit path must remain safe under pauses, crashes, and stale owners.

The design material explicitly distinguishes:

- lease ownership, which is necessary but insufficient
- fencing, which prevents stale writers from committing after ownership moves

## Decision

Workflow executions use single-writer ownership enforced by leases plus
monotonic fencing tokens.

That ownership model applies at the durable commit boundary:

- only the active owner may commit checkpoints
- the store validates the fence token when persisting workflow state
- stale owners must fail durable writes even if they resume after a pause

## Consequences

- Multi-node ownership safety is enforced at the storage boundary, not by
  trusting process liveness alone.
- The runtime keeps one serialized apply and commit path per execution.
- Exact lease TTLs, renewal cadence, and polling intervals are operational
  tuning details and are not part of the durable decision.

## Sources

- `docs/plans/durable-workflow-system-design.md`
- `docs/plans/runic-research.md`
