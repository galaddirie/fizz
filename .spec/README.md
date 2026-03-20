# Spec Layer

This directory captures the durable workflow runtime and editor contracts that
should stay true over time, along with the architectural decisions that shape
those contracts.

## Specs — Workflow Runtime

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
- `specs/workflow-run-lifecycle.spec.md`
  - Run states, Postgres statuses, valid transitions, terminal states, passivation sweep.
- `specs/workflow-durable-timers.spec.md`
  - Timer state machine, polling, cancellation, and kernel/platform boundary.
- `specs/workflow-storage.spec.md`
  - Checkpoint format, SQLite 1:1 mapping, passivation tiers, rehydration, Litestream, schema versioning.
- `specs/workflow-ownership.spec.md`
  - Lease acquisition/renewal/expiry, fence token monotonicity, stale owner rejection.
- `specs/workflow-activity-dispatch.spec.md`
  - Dispatch flow, SchedulerPolicy, durable mode events, pluggable executors, recovery, skip/fail.
- `specs/workflow-error-handling.spec.md`
  - Step-level retry/skip, workflow failure states, failure mitigation table, no compensation in v1.
- `specs/workflow-triggers.spec.md`
  - Trigger registration lifecycle, fire routing, event dedup, compiler integration, behaviour composition.

## Specs — Workflow Editor

- `specs/editor.state-model.spec.md`
  - State taxonomy (authored, published, runtime, ephemeral), ownership boundaries, LiveView assigns.
- `specs/editor.draft-session.spec.md`
  - DraftSession GenServer lifecycle, operation model, undo/redo, persistence contracts.
- `specs/editor.collaboration.spec.md`
  - Concurrency semantics (LWW, optimistic apply), presence metadata, PubSub topics.
- `specs/editor.canvas.spec.md`
  - Connection validation rules, node type visual contracts, keyboard shortcuts, layout constants.
- `specs/editor.step-config.spec.md`
  - Config schema to UI field mapping, expression editing, credential resolution, subnode slots.
- `specs/editor.validation.spec.md`
  - Three validation tiers (operation, persist, publish), error structure, per-tier rules.
- `specs/editor.execution.spec.md`
  - Test run lifecycle, PubSub execution events, debug mode, on-demand I/O loading.
- `specs/editor.version-lifecycle.spec.md`
  - Draft/published/archived transitions, publish pipeline, hash semantics, trigger impact.

## Decisions — Workflow Runtime

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
- `decisions/trigger-registry-architecture.md`
  - ETS-backed trigger registration cache with LISTEN/NOTIFY sync for sub-millisecond webhook routing.

## Decisions — Workflow Editor

- `decisions/operation-based-collaboration.md`
  - Operation-based editing over OT/CRDT and pessimistic locking; server-authoritative GenServer.
- `decisions/periodic-persistence.md`
  - DraftSession batches DB writes on a 5s timer instead of per-keystroke saves.

## Exclusions

The spec layer intentionally omits roadmap phases, rollout sequencing, tuning
numbers, proposed module trees, and other material that is either still fluid
or only useful as planning context.
