# ContinueAsNew Boundary

Status: accepted

## Context

Long-lived workflow executions need a way to compact history without changing
their logical identity. The planning material identified ContinueAsNew as the
mechanism but left its boundary, lineage, and carry-forward semantics open.

## Decision

ContinueAsNew is an explicit workflow/runtime action taken at a safe checkpoint
boundary.

The continuation contract is:

- the parent run checkpoints before handoff
- the child run starts from the same workflow definition and version unless a
  separate migration flow says otherwise
- only an explicit serializable `carry_forward` payload plus selected workflow
  metadata crosses into the child run
- hidden graph internals, pending runnables, and implicit accumulator state do
  not cross the boundary automatically
- the parent run becomes terminal as `continued`
- lineage is recorded in control-plane metadata so operators can traverse the
  chain as one logical workflow history

Thresholds may recommend continuation, but the store adapter must not trigger it
implicitly as part of checkpoint persistence.

## Consequences

- History compaction remains predictable and visible to operators.
- Continuation stays separate from code-version migration and separate from
  persistence-layer pruning.
- Archived parent runs remain inspectable according to normal retention policy.

## Related decisions

- `per-execution-sqlite-store.md` — full-log checkpointing is the persistence
  strategy whose growth this boundary mitigates
- `postgres-control-plane.md` — the store that records continuation lineage
  metadata

## Sources

- `docs/plans/durable-workflow-system-design.md`
- `docs/plans/compiler-and-runtime-context-design.md`
