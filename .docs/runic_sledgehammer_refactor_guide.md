# Sledgehammer Refactor Guide

This guide is the companion to `.docs/runic_durable_orchestration_assessment.md`.

Purpose:

- stop extending the current `lib/fizz/workflows` and `lib/fizz/executions` assumptions
- separate workflow authoring from workflow runtime
- move Fizz toward a durable orchestration platform that uses Runic as an execution kernel, not as the long-lived control plane

This is intentionally a **sledgehammer** plan, not an incremental polish pass.

## 1. The core decision

We are making one hard architectural split:

- `lib/fizz/workflows` becomes the **authoring and publishing** domain
- durable runtime state moves out of the current `Execution` / `StepExecution` model into a new orchestration domain

The mistake in the initial design was treating these as the same problem.

Today we have:

- mutable editor drafts
- immutable published snapshots
- a single execution row trying to hold runtime truth
- step execution rows trying to represent everything from retries to fan-out to waiting
- ephemeral PubSub events pretending to be lifecycle events

That shape does not scale to:

- signals
- timers
- human approvals
- child workflows
- dormant instances
- replay
- durable recovery

## 2. Sledgehammer rules

These are non-negotiable.

1. Do not add any new durable workflow features to `Execution.context`.
2. Do not add timers, signals, approvals, or leases to `Execution.waiting_for`.
3. Do not turn `StepExecution` into a universal ledger for retries, fan-out, human tasks, and wakeups.
4. Do not treat `Fizz.Executions.Events` as the source of truth. It is a broadcast helper, not a durable journal.
5. Do not let `NodeGroup` remain an execution boundary. It is editor metadata unless explicitly compiled into a runtime construct.
6. Do not derive production contracts from mutable drafts.
7. Do not keep growing `lib/fizz/executions.ex` as if it were the orchestration engine.
8. Do not bolt durable orchestration semantics onto the current `Runic.Runner` process model.

If a change violates one of those rules, it is the wrong change.

## 3. The bad assumptions we are deleting

### 3.1 `WorkflowVersion` is the runtime definition

Current assumption:

- `Fizz.Workflows.WorkflowVersion` is an immutable snapshot and therefore good enough for execution reproducibility.

Why this is wrong:

- it stores editor-facing `steps`, `connections`, and `groups`
- it stores a UI/source hash, not a compiled orchestration definition
- it has no versioned runtime semantics for wait states, timers, signals, or activity boundaries

Evidence:

- `lib/fizz/workflows/workflow_version.ex`

Correction:

- keep `WorkflowVersion` as an authoring snapshot
- introduce a compiled definition artifact for runtime execution
- production execution runs against compiled published definitions, not raw editor graphs

### 3.2 `Execution` is both the workflow instance and the runtime state container

Current assumption:

- one `executions` row can hold lifecycle state, accumulated context, output, errors, waiting state, and timing

Why this is wrong:

- durable orchestration needs append-only history plus snapshots
- `context` is a mutable bag of outputs, not an auditable transition log
- `waiting_for` is too weak to model timers, signals, human tasks, child barriers, and leases
- a single mutable row cannot safely express ordered durable transitions

Evidence:

- `lib/fizz/executions/execution.ex`
- `lib/fizz/executions.ex`
- `lib/fizz/runtime/expression/context.ex`

Correction:

- replace `Execution` as source of truth with:
  - `WorkflowInstance`
  - `WorkflowEvent`
  - `WorkflowSnapshot`
  - `WorkflowSignal`
  - `WorkflowTimer`
  - `WorkflowActivity`
  - `WorkflowHumanTask`
  - `WorkflowLease`

### 3.3 `StepExecution` is the universal runtime primitive

Current assumption:

- every meaningful unit of runtime behavior is a step execution row

Why this is wrong:

- internal pure graph evaluation should not always become durable per-step rows
- external activities, retries, fan-out items, and human tasks are different runtime objects
- durable orchestration needs activity leasing and idempotency, not just step attempt rows

Evidence:

- `lib/fizz/executions/step_execution.ex`
- `lib/fizz/executions.ex`

Correction:

- use Runic internal transitions for in-activation computation
- persist durable runtime boundaries as first-class records:
  - activities
  - timers
  - human tasks
  - child workflows

`StepExecution` should either disappear or survive only as a projection for UI/debugging.

### 3.4 PubSub events are runtime history

Current assumption:

- `Fizz.Executions.Events.emit/4` is a canonical lifecycle event layer

Why this is wrong:

- it logs, broadcasts, and emits telemetry, but it does not durably append anything
- if the process crashes, the event is gone
- consumers cannot replay from it

Evidence:

- `lib/fizz/executions/events.ex`
- `lib/fizz/executions/pub_sub.ex`

Correction:

- durable append comes first
- projection broadcast comes second
- telemetry comes third

The write path must be:

1. append durable event
2. update projection/snapshot
3. broadcast UI event

not the other way around.

### 3.5 `NodeGroup` is an execution boundary

Current assumption:

- node groups are visual and execution boundaries exposing a single output

Why this is wrong:

- the durable architecture cannot let editor grouping dictate runtime ownership semantics
- groups might later compile to subflows, but that must be explicit
- most grouping is UI organization, not orchestration topology

Evidence:

- `lib/fizz/workflows/embeds/node_group.ex`
- `lib/fizz/workflows/validator.ex`

Correction:

- treat groups as editor-only metadata by default
- only explicit runtime constructs compile into execution boundaries

### 3.6 Draft settings are runtime policy

Current assumption:

- `WorkflowDraft.settings` can carry runtime behavior like `timeout_ms` and `max_retries`

Why this is wrong:

- draft settings are mutable and editor-scoped
- runtime policy belongs on compiled definitions and activity policies
- preview and production policy resolution are different problems

Evidence:

- `lib/fizz/workflows/workflow_draft.ex`

Correction:

- authoring defaults can remain in the draft
- published runtime policy must be compiled and frozen with the definition version

### 3.7 Runtime expression context can read from `execution.context`

Current assumption:

- `Fizz.Runtime.Expression.Context` can treat `Execution.context` as durable step output truth

Why this is wrong:

- durable state will live in snapshots plus event projections
- not all runtime state is a flat per-step output map
- waiting on signals, timers, or child workflows must also shape the context

Evidence:

- `lib/fizz/runtime/expression/context.ex`
- `lib/fizz/executions/execution.ex`

Correction:

- expression context must be built from the active snapshot + runtime projections
- `execution.context` should not remain the storage anchor for runtime truth

## 4. What stays vs what moves

### Keep in `lib/fizz/workflows`

These remain part of the authoring domain:

- `workflow.ex`
- `workflow_draft.ex`
- `workflow_version.ex`
- `embeds/step.ex`
- `embeds/connection.ex`
- `embeds/node_group.ex`
- `validator.ex`
- `contract.ex`

But their responsibilities change:

- authoring-only validation
- publishing
- compiler input
- preview support

They stop being the runtime system.

### Move runtime orchestration out of `lib/fizz/executions`

Recommended new bounded context:

- `lib/fizz/orchestration`

Recommended modules:

- `fizz/orchestration/workflow_instance.ex`
- `fizz/orchestration/workflow_event.ex`
- `fizz/orchestration/workflow_snapshot.ex`
- `fizz/orchestration/workflow_signal.ex`
- `fizz/orchestration/workflow_timer.ex`
- `fizz/orchestration/workflow_activity.ex`
- `fizz/orchestration/workflow_human_task.ex`
- `fizz/orchestration/workflow_child.ex`
- `fizz/orchestration/workflow_lease.ex`
- `fizz/orchestration/activator.ex`
- `fizz/orchestration/compiler_bridge.ex`
- `fizz/orchestration/projections/*.ex`
- `fizz/orchestration/pub_sub.ex`

Why a new context instead of mutating `Executions` in place:

- `execution` is already overloaded
- `orchestration` makes the control-plane responsibilities explicit
- it gives us a clean boundary for replacing the old model

## 5. Module-by-module refactor plan

### 5.1 `lib/fizz/workflows/workflow.ex`

Current role:

- top-level workflow metadata and publish pointers

New role:

- stays mostly intact
- remains the aggregate root for authoring
- should not gain runtime status, timers, execution counters, or orchestration fields

Allowed additions:

- none related to runtime durability
- maybe compiler metadata or publishing constraints

### 5.2 `lib/fizz/workflows/workflow_draft.ex`

Current role:

- mutable editor state plus default settings

New role:

- editor-only source of truth for mutable design state
- preview compiler input

Required changes:

- document that `settings` are authoring defaults only
- do not consume draft settings directly in production execution

### 5.3 `lib/fizz/workflows/workflow_version.ex`

Current role:

- immutable snapshot of editor graph with `source_hash`

New role:

- immutable authoring snapshot
- parent record for compiled runtime definition

Required changes:

- stop implying that `source_hash` equals execution reproducibility
- add a compiled runtime artifact:
  - either a new `workflow_definition_versions` table
  - or a compiled blob attached to `workflow_versions`

Recommended new fields/table content:

- compiled definition version
- compiler version
- runic build artifact or normalized definition graph
- runtime policy bundle
- derived contract

### 5.4 `lib/fizz/workflows/contract.ex`

Current role:

- derives workflow input/output contract from `WorkflowDraft`

New role:

- for editor previews: still derive from draft
- for production/runtime APIs: derive from published compiled definition

Required change:

- split APIs into:
  - `derive_preview/1`
  - `derive_published/1`

Do not let production API behavior depend on mutable drafts.

### 5.5 `lib/fizz/workflows/validator.ex`

Current role:

- validates draft integrity and group semantics

New role:

- split into:
  - authoring validator
  - compile validator

Authoring validator checks:

- editor graph correctness
- UI grouping rules
- slot connectivity

Compile validator checks:

- valid trigger topology
- explicit wait/activity boundaries
- no unsupported dynamic cycles
- publishability into durable runtime

Big rule:

- `NodeGroup` rules belong in authoring validation, not in orchestration semantics by default

### 5.6 `lib/fizz/executions/execution.ex`

Current role:

- mutable execution state
- lifecycle timestamps
- context/output/error/waiting state

New role:

- deprecated as source of truth
- optionally retained as a projection or compatibility struct during migration

Fields to kill as authoritative runtime fields:

- `context`
- `output`
- `error`
- `waiting_for`

Equivalent new sources:

- current projection from `workflow_events`
- `workflow_snapshots.summary`
- activity/timer/signal projections

Recommended rename:

- long term replace `Execution` with `WorkflowInstance`

### 5.7 `lib/fizz/executions/step_execution.ex`

Current role:

- one row per step run / retry / fan-out item

New role:

- not the core runtime primitive

Options:

- delete and replace with `WorkflowActivity` + `WorkflowActivityAttempt`
- or keep as a projection emitted for UI/debugging from durable event history

What not to do:

- do not add `signal_id`
- do not add `timer_id`
- do not add `human_task_id`
- do not add generic orchestration metadata blobs to keep it alive

That would only preserve the wrong model.

### 5.8 `lib/fizz/executions/events.ex`

Current role:

- builds and broadcasts event envelopes

New role:

- split into:
  - durable event appender
  - projection broadcaster
  - telemetry emitter

Required shape:

- `append_event/4` writes to `workflow_events`
- `broadcast_projection_update/2` pushes UI updates
- telemetry is downstream of durable commit

### 5.9 `lib/fizz/executions/pub_sub.ex`

Current role:

- topic subscription and runtime broadcast helper

New role:

- projection update subscription only
- no implication that PubSub message == authoritative lifecycle event

### 5.10 `lib/fizz/executions.ex`

Current role:

- giant CRUD/service context over `Execution` and `StepExecution`

New role:

- shrink to compatibility façade during migration
- move orchestration behavior to `Fizz.Orchestration`

Functions that should move:

- create/start instance
- signal instance
- pause/resume/cancel
- append runtime events
- queue/wake activations
- manage activities

Functions that may remain temporarily:

- UI query helpers backed by projections
- old API adapters calling the new orchestration layer

### 5.11 `lib/fizz/runtime/expression/context.ex`

Current role:

- builds expression variables from `Execution` + runtime state

New role:

- build from:
  - `WorkflowInstance` projection
  - snapshot summary
  - step output projection
  - current activity/signal/timer context

Stop reading `execution.context` as the authoritative state container.

## 6. Target data model

### 6.1 Keep authoring tables

- `workflows`
- `workflow_drafts`
- `workflow_versions`

### 6.2 Add runtime tables

- `workflow_instances`
- `workflow_events`
- `workflow_snapshots`
- `workflow_signals`
- `workflow_timers`
- `workflow_activities`
- `workflow_activity_attempts`
- `workflow_human_tasks`
- `workflow_children`
- `workflow_leases`
- `workflow_outbox`

### 6.3 Optional compatibility projections

- `execution_views`
- `step_execution_views`

These can back the current UI while the new runtime is being introduced.

## 7. The new runtime boundaries

### 7.1 Authoring boundary

Input:

- drafts and published editor graphs

Output:

- validated published version
- compiled runtime definition
- derived published contract

### 7.2 Orchestration boundary

Input:

- compiled definition
- start commands
- signals
- timer firings
- activity completions
- human approvals
- child completions

Output:

- append-only workflow events
- updated snapshots
- new timers
- queued activities
- projection updates

### 7.3 Activity boundary

Input:

- durable activity tasks

Output:

- durable completion/failure events
- heartbeats
- cancellation acknowledgements

## 8. Recommended file layout after refactor

```text
lib/fizz/workflows/
  workflow.ex
  workflow_draft.ex
  workflow_version.ex
  contract.ex
  validator.ex
  compiler.ex
  compiled_definition.ex
  publisher.ex
  embeds/
    step.ex
    connection.ex
    node_group.ex

lib/fizz/orchestration/
  workflow_instance.ex
  workflow_event.ex
  workflow_snapshot.ex
  workflow_signal.ex
  workflow_timer.ex
  workflow_activity.ex
  workflow_activity_attempt.ex
  workflow_human_task.ex
  workflow_child.ex
  workflow_lease.ex
  activator.ex
  dispatcher.ex
  projections/
    execution_view.ex
    step_execution_view.ex
  pub_sub.ex

lib/fizz/executions.ex
  # temporary compatibility facade only
```

## 9. The actual refactor sequence

### Phase 0: Freeze the wrong model

Immediately stop doing these things:

- adding fields to `Execution`
- adding new uses of `Execution.context`
- adding more runtime semantics to `waiting_for`
- adding more lifecycle meaning to `StepExecution`
- adding durable behavior to `Events.emit/4`

This is the first real win: stop digging.

### Phase 1: Introduce the new orchestration tables and context

Create:

- new runtime tables
- `Fizz.Orchestration` context
- minimal `WorkflowInstance` + `WorkflowEvent` + `WorkflowSnapshot`

Do not delete old tables yet.

### Phase 2: Introduce a compiler from `WorkflowVersion` to runtime definition

Build:

- `Fizz.Workflows.Compiler`
- published compile artifact
- compiler versioning

Publishing flow becomes:

1. validate draft
2. create `WorkflowVersion`
3. compile published definition
4. persist compiled artifact
5. derive published contract

### Phase 3: Build the activation engine

Implement:

- lease acquisition
- snapshot rehydration
- Runic activation burst
- event append + snapshot write transaction

This is where Runic enters as a kernel.

### Phase 4: Model external runtime boundaries

Add first-class durable support for:

- signals
- timers
- activities
- human tasks
- child workflows

Do not route these through `StepExecution`.

### Phase 5: Replace old event flow

Make durable append the only source of truth.

New write path:

1. append event
2. update projections
3. broadcast projection change

Refactor current `Fizz.Executions.Events` usage into adapters around the new orchestration event appender.

### Phase 6: Convert the UI and API to projections

Update:

- execution show pages
- workflow show pages
- workflow contract endpoints
- any step timeline UI

so they read from projections and history, not from mutable execution state bags.

### Phase 7: Delete or demote old runtime modules

At cutover:

- `Execution` becomes a compatibility projection or is deleted
- `StepExecution` becomes a projection or is deleted
- `Fizz.Executions` becomes a thin façade over `Fizz.Orchestration`

## 10. Compatibility plan

We do not need a big-bang UI cutover, but we do need a big-bang runtime truth cutover.

Recommended compatibility strategy:

- new runtime writes authoritative orchestration events
- projection builders maintain execution-like read models for current UI
- old APIs read from projections until the UI is migrated

That means:

- compatibility at the read layer
- no compatibility at the write-truth layer

Do not dual-write `Execution.context` as a long-term plan.

## 11. Preview executions vs production executions

We should explicitly split these.

### Preview

- can compile directly from `WorkflowDraft`
- can run more ephemerally
- can use shorter retention
- should still use the same compiler and activation semantics where possible

### Production

- always runs against a published compiled definition
- always appends durable events
- always uses timers/signals/activities through the orchestration layer

Do not let preview shortcuts leak into production runtime architecture.

## 12. Tests we need before deleting the old model

### Compiler tests

- draft -> compiled definition is stable
- published version + compiler version is reproducible
- contracts derived from compiled definitions are stable

### Orchestration tests

- signal acceptance is durable
- timer fire wakes dormant instance
- activity dispatch is durable before external side effect starts
- replay from snapshot + events reproduces instance state
- paused instances stay paused
- child workflow fan-in resumes parent correctly

### Projection tests

- execution-like view matches current UI requirements
- history view preserves event order and payloads

## 13. The practical kill list

These are the assumptions we should actively delete from the codebase:

- `Execution.context` is the runtime source of truth
- `Execution.waiting_for` is enough to model durable waiting
- `StepExecution` is the durable runtime ledger
- `Events.emit/4` is a canonical lifecycle store
- `NodeGroup` is an execution boundary by default
- `WorkflowVersion.source_hash` equals executable identity
- production contracts can come from mutable drafts
- `Fizz.Executions` should remain the main workflow runtime context

## 14. Final recommendation

Do not try to evolve the current `Execution` and `StepExecution` model into durable orchestration.

That path will produce:

- more mutable fields
- more overloaded tables
- worse semantics
- harder migration later

The right move is:

1. freeze the old assumptions
2. introduce a new orchestration context
3. keep `lib/fizz/workflows` as authoring/publishing
4. let compatibility survive only as projections and façade APIs

That is the cleanest way to get from the current schema-first execution model to the durable Runic-based orchestration design.
