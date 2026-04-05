# Runic As Execution Kernel

Status: accepted

## Context

The durable workflow runtime needs a replayable execution core without building
its own scheduler, executor, checkpoint loop, and worker supervision stack from
scratch.

The planning material consistently treats Runic as that core:

- workflows are durable values, not opaque interpreter state
- `Runic.Runner` already owns execution, scheduling, checkpointing, and recovery primitives
- the platform still needs a surrounding control plane

## Decision

Fizz will treat Runic as the workflow execution kernel.

That means:

- authored workflows compile into Runic workflows
- worker execution, runnable scheduling, checkpoint strategy, and replay use Runic primitives
- the platform layer wraps the kernel rather than replacing it

## Consequences

- Specs separate kernel guarantees from platform guarantees.
- The platform still owns leasing, fencing, durable timers, signal delivery,
  storage lifecycle, and operator-facing semantics.
- Proposed module trees, rollout phases, and individual worker names are not
  part of this decision because they are implementation planning detail rather
  than durable architecture.

## Related decisions

- `programmatic-meta-ref-wiring.md` — the compilation strategy for assembling
  Runic workflows from authored definitions
- `per-execution-sqlite-store.md` — the storage model the platform wraps around
  the kernel

## Sources

- `docs/plans/runic-research.md`
- `docs/plans/durable-workflow-system-design.md`
