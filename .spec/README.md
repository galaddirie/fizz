# Spec Layer

This directory captures the durable workflow runtime contracts that should stay
true over time, along with the architectural decisions that shape those
contracts.

## Specs

- `specs/workflow-definitions.spec.md`
  - Authored workflow definition/version shape and draft-to-published lifecycle.
- `specs/workflow-expression-language.spec.md`
  - User-facing expression surface, namespaces, modes, and validation timing.
- `specs/workflow-compilation-runtime-context.spec.md`
  - Compilation boundary, hash semantics, and runtime context delivery.
- `specs/workflow-execution-semantics.spec.md`
  - Durable execution guarantees, replay boundaries, and recovery rules.
- `specs/workflow-continuation.spec.md`
  - ContinueAsNew boundary, carry-forward semantics, and lineage rules.
- `specs/workflow-signal-delivery.spec.md`
  - External signal delivery, dedup scope, and wakeup semantics.
- `specs/steps-and-integration-auth.spec.md`
  - Implemented step registry, executor, provider, and credential-resolution contracts.

## Decisions

- `decisions/runic-as-execution-kernel.md`
  - The durable runtime is built around Runic as the execution kernel.
- `decisions/per-execution-sqlite-store.md`
  - Each workflow execution owns its own SQLite durability shard.
- `decisions/postgres-control-plane.md`
  - Postgres is the control-plane store for global queries, leases, signals, timers, and lineage.
- `decisions/single-writer-leasing-and-fencing.md`
  - Multi-node ownership is protected with leases plus fencing tokens.
- `decisions/durable-timer-model.md`
  - Durable timers are platform-level Postgres rows; Runic SchedulerPolicy owns in-process timeouts and retry.
- `decisions/signal-dedup-scope.md`
  - Signal idempotency is scoped per workflow run, not globally.
- `decisions/continue-as-new-boundary.md`
  - ContinueAsNew is an explicit continuation boundary with lineage and carry-forward rules.
- `decisions/expression-filter-catalog.md`
  - The workflow expression system uses a bounded v1 filter catalog with strict validation.
- `decisions/programmatic-meta-ref-wiring.md`
  - Compiled workflows generate quoted Runic components with explicit meta references.

## Exclusions

The spec layer intentionally omits roadmap phases, rollout sequencing, tuning
numbers, proposed module trees, and other material that is either still fluid
or only useful as planning context.
