# Workflow Runtime Maintainability Refactor - Design Document

| | |
|---|---|
| **Status** | Draft |
| **Authors** | Codex |
| **Reviewers** | [name(s)] |
| **Last updated** | 2026-05-28 |
| **Related docs** | [Workflow Ownership](../spec/specs/workflow-ownership.spec.md), [Workflow Storage](../spec/specs/workflow-storage.spec.md), [Workflow Run Lifecycle](../spec/specs/workflow-run-lifecycle.spec.md), [Workflow Signal Delivery](../spec/specs/workflow-signal-delivery.spec.md), [Workflow Durable Timers](../spec/specs/workflow-durable-timers.spec.md), [Durable Workflow System Design](durable-workflow-system-design.md) |

---

## 1. TL;DR

The workflow runtime works, but its implementation has grown around a few large modules and several partially duplicated runtime paths. The refactor should keep `Fizz.Workflows` as the public context facade while moving implementation details into small internal modules with single responsibilities. The first priority is correctness: all durable writes must be fenced, passivation must not stop active work, and timer/signal delivery must have explicit bounded acknowledgement semantics. Only after those safety fixes should we reduce module size, duplicate helpers, and web-to-domain coupling.

---

## 2. Context & Problem

### 2.1 Background

The workflow system now includes authoring, publishing, Runic compilation, per-run SQLite checkpointing, Postgres leases, timers, signals, passivation, draft-session collaboration, and LiveView debug/replay surfaces.

The current code clusters too much of that behavior in a few places:

- `lib/fizz/workflows.ex` is the public context and also implements run lifecycle, timer/signal row operations, worker wakeup, passivation helpers, and step-execution replay.
- `lib/fizz/workflows/compiler/assembler.ex` owns graph assembly, split/join scope planning, built-in step semantics, runtime callback helpers, and test-facing helpers.
- `lib/fizz/workflows/runner/worker.ex` owns execution state, lifecycle transitions, PubSub payload construction, checkpointing, retry/timer behavior, and failure finalization.
- The LiveView editor reaches into internal workflow modules instead of going through a smaller authoring/draft facade.

### 2.2 Problem statement

The runtime has two related problems:

1. Correctness-sensitive ownership paths are not expressed once. Full checkpoint writes are fenced, but fact writes, terminal status updates, passivation, and delivery timeouts follow separate paths with different safety properties.
2. The code is harder to change than it needs to be. Large modules mix public API, orchestration, persistence, projection, and low-level helpers. That increases future change cost and makes small fixes harder to review.

### 2.3 Why now

The workflow runtime has enough behavior to warrant tightening boundaries before more node semantics, editor behavior, or runtime recovery modes are added. The review found concrete safety issues, so this is not only cleanup.

---

## 3. Goals & Non-goals

### 3.1 Goals

- Ensure every mutating SQLite store operation is authorized by the current unexpired lease and fence token.
- Prevent passivation from cancelling active or queued workflow work.
- Make timer and signal delivery acknowledgement bounded and explicit, avoiding redelivery after a late successful delivery.
- Keep one public `Fizz.Workflows` context facade while moving implementation details into internal modules.
- Reduce the largest workflow modules by extracting cohesive behavior, not by adding generic indirection.
- Move web serialization and LiveView-specific payload behavior out of core workflow modules.
- Add characterization/regression tests before changing behavior in runtime ownership, delivery, and compiler semantics.

### 3.2 Non-goals

- **No public context split.** External callers should keep using `Fizz.Workflows`; the split is internal.
- **No rewrite of the workflow engine.** Runic remains the execution kernel.
- **No broad editor redesign.** This plan only narrows editor/domain coupling where it affects workflow maintainability.
- **No new abstraction for every repeated line.** Boilerplate like `start_link/1` is only worth extracting when it removes behavior duplication or prevents drift.

### 3.3 Success criteria

- Stale or expired owners cannot mutate workflow SQLite state, including fact rows.
- A long-running active step is not passivated because `last_active_at` is old.
- Timer/signal timeout tests prove claims are released, retried, or acknowledged exactly according to the chosen delivery contract.
- `Fizz.Workflows` exposes fewer `@doc false` runtime internals.
- Step execution replay/projection is owned by one module and reused by web/read paths.
- Compiler split/join behavior remains covered by existing semantics tests after extracting planner code.

---

## 4. Overview

### 4.1 Approach

Do this as a sequence of small PRs. Start with tests around the unsafe paths, then introduce focused modules that own those paths. Keep the facade stable and move private implementation behind it.

The first implementation layer should be runtime safety:

- fenced store writes
- active-work-aware passivation
- centralized run finalization
- bounded timer/signal delivery

The second layer should be organization:

- `Workflows.Runtime.*` modules for run, timer, signal, passivation, and projection internals
- `Workflows.Drafts` facade functions for editor/draft-session operations
- compiler planner/executor helper extraction

### 4.2 Focused plan packet

The implementation details are split across focused planning documents so the spec layer can stay small and current-truth oriented:

| Plan | Scope |
|---|---|
| [Workflow Runtime Ownership and Storage Safety](workflow-runtime-ownership-storage-safety.md) | Fenced SQLite mutations, lease-expiry authorization, fact conflict behavior, lease FK. |
| [Workflow Runtime Lifecycle and Passivation Safety](workflow-runtime-lifecycle-passivation.md) | Active-work-aware passivation, WAL checkpoint preservation, terminal finalization. |
| [Workflow Runtime Timer and Signal Delivery Semantics](workflow-runtime-delivery-semantics.md) | Bounded worker delivery, timeout acknowledgement contract, immediate signal alignment. |
| [Workflow Runtime Internal Boundary](workflow-runtime-internal-boundaries.md) | Runtime module extraction while preserving the public `Fizz.Workflows` facade. |
| [Workflow Runtime Editor Boundary](workflow-runtime-editor-boundary.md) | Draft facade functions and web-owned payload serialization. |
| [Workflow Runtime Compiler Boundary](workflow-runtime-compiler-boundary.md) | Scope planner, runtime callbacks, switch matching, expression helper ownership. |
| [Workflow Runtime Maintainability Refactor - Implementation Order](workflow-runtime-implementation-order.md) | Cross-plan sequencing, phase gates, global rollback strategy. |

### 4.3 Target internal shape

Keep `Fizz.Workflows` as the public entrypoint. Internally, move toward:

| Module | Responsibility |
|---|---|
| `Fizz.Workflows.Authoring` | Definition CRUD, draft/publish lifecycle, version lookup helpers. |
| `Fizz.Workflows.Drafts` | Public facade over `DraftSession` join/apply/undo/redo/persist/editor-state operations. |
| `Fizz.Workflows.Runtime.Runs` | Start, wake, cancel, complete, fail, passivate, lease release, terminal cleanup. |
| `Fizz.Workflows.Runtime.Timers` | Timer create/claim/recover/release/mark/cancel row operations. |
| `Fizz.Workflows.Runtime.Signals` | Signal inbox create/claim/recover/release/mark row operations and idempotency. |
| `Fizz.Workflows.Runtime.StepExecutions` | Read-model projection from Runic events plus fact loading. |
| `Fizz.Workflows.Runtime.Delivery` | Shared bounded delivery pattern for timer/signal claims. |
| `Fizz.Workflows.Store.SqliteStore` | Store behavior plus a single fenced write path for all SQLite mutations. |
| `Fizz.Workflows.Compiler.ScopePlanner` | Split/join/aggregator scope decisions currently embedded in `Assembler`. |
| `Fizz.Workflows.Compiler.RuntimeCallbacks` | Runtime callback helpers currently embedded in `Assembler`. |

### 4.4 Key design decisions

- **Keep `Fizz.Workflows` as a facade.** Splitting public contexts now would spread workflow ownership across the application. A facade preserves call sites while allowing internal cleanup.
- **Fix correctness before reducing code.** Some duplication is harmless; stale writes and duplicate delivery are not.
- **Prefer operation-specific modules over generic helpers.** A small `Runtime.Timers` module is clearer than a generic claim-state framework until timer and signal behavior truly converges.
- **Move behavior to source-of-truth modules.** Switch matching should live with the switch executor. Expression detection should live with `Expressions`. Step execution projection should live in one projection module.

---

## 5. Specs To Update

These stable spec changes should land near the implementation PRs that enforce them.

### 5.1 Workflow ownership

Update `workflows.ownership.fence_validation_at_commit` in [workflow-ownership.spec.md](../spec/specs/workflow-ownership.spec.md) to make two points explicit:

- fence validation applies to every SQLite mutation, not only full checkpoint writes
- the lease must still be unexpired at authorization time

Add scenarios:

- `workflows.ownership.stale_fact_write_fenced`
- `workflows.ownership.expired_owner_write_rejected`
- `workflows.ownership.terminal_update_requires_owner`

### 5.2 Workflow storage

Update `workflows.storage.fact_level_persistence` in [workflow-storage.spec.md](../spec/specs/workflow-storage.spec.md):

- fact rows share the same fenced write authorization as the canonical checkpoint
- fact upserts must not allow stale owners to overwrite existing content

### 5.3 Workflow run lifecycle

Update passivation requirements in [workflow-run-lifecycle.spec.md](../spec/specs/workflow-run-lifecycle.spec.md):

- passivation may only stop a live worker that reports no active/queued work
- DB-only passivation is allowed only for sleeping/passivated-eligible runs with a valid checkpoint
- `last_active_at` is a candidate filter, not sufficient proof of idleness

Add scenarios:

- `workflows.run_lifecycle.active_work_not_passivated`
- `workflows.run_lifecycle.sleeping_checkpoint_can_passivate`

### 5.4 Timer and signal delivery

Update [workflow-durable-timers.spec.md](../spec/specs/workflow-durable-timers.spec.md) and [workflow-signal-delivery.spec.md](../spec/specs/workflow-signal-delivery.spec.md):

- delivery calls to workers must be bounded
- timeout behavior must be one of: release claim for retry, record a delivery-in-flight token until acknowledgement, or mark skipped/failed by an explicit state transition
- immediate signal acceptance should use the same delivery path as drain/poll delivery, or only persist and let drain deliver

Add scenarios:

- `workflows.durable_timers.delivery_timeout_releases_claim`
- `workflows.signal_delivery.delivery_timeout_releases_claim`
- `workflows.signal_delivery.accept_does_not_bypass_router_limits`

### 5.5 Spec exceptions

Several spec exception blocks still describe implementation as pending even though code exists now. Update exceptions after each implementation PR so specs accurately say which guarantees are implemented and which remain pending.

---

## 6. Detailed Plan

### 6.1 Runtime safety fixes

#### Fenced SQLite writes

**Current issue.** `SqliteStore.save/3` confirms the fence before checkpoint writes, but `save_fact/3` writes facts without the Postgres fence check.

**Plan.**

- Create one private `with_fenced_write(run_id, store_state, fun)` helper in `SqliteStore`.
- Have `save/3`, `checkpoint/3`, and `save_fact/3` use it.
- Include `lease_expiry > NOW()` in the Postgres authorization query.
- Keep the SQLite transaction inside the fenced write path.
- Decide whether fact hash conflicts should be `DO NOTHING` instead of `DO UPDATE` if content hashes are expected to be immutable.

**Tests.**

- stale fence rejects `save_fact/3`
- expired lease rejects `save/3` and `save_fact/3`
- current owner can still save checkpoint and facts

#### Run finalization

**Current issue.** Completion, failure, cancellation, abnormal termination, timer cancellation, broadcasts, checkpointing, and lease release are spread across worker and context code.

**Plan.**

- Introduce one internal finalization path for terminal transitions.
- Make finalization responsible for final checkpoint, terminal status update, pending timer cancellation, lease release, and broadcast.
- Ensure abnormal worker termination releases or stops renewing the lease.
- Consider requiring terminal updates to be fenced by current owner for active runs.

**Tests.**

- abnormal worker termination releases the lease or stops renewal
- terminal transition cancels pending timers
- stale owner cannot mark a run failed after losing ownership

#### Active-work-aware passivation

**Current issue.** A stale `last_active_at` can make a `:running` run eligible for passivation even if the worker has active tasks.

**Plan.**

- Add `Worker.idle?/1` or `Worker.passivate/2`.
- Have passivation ask the worker for idleness before stopping it.
- Treat `last_active_at` as a candidate query only.
- For no-worker cases, only passivate if the run is `:sleeping` or there is a valid checkpoint and no active owner.
- Do not delete local SQLite files if WAL checkpoint fails.

**Tests.**

- long-running active task is not passivated
- sleeping run with checkpoint can passivate
- WAL checkpoint failure preserves local files

#### Timer/signal delivery

**Current issue.** Pollers use timed tasks, but worker delivery is an infinite GenServer call. A killed poller task may leave an event processed late while the claim is later recovered and redelivered.

**Plan.**

- Add a bounded worker delivery API with an explicit timeout.
- On timeout, either release claim for retry before the worker sees it or track a delivery token so late acknowledgements are not redelivered.
- Make immediate signal delivery use the router path, or only accept durably and let `drain/1` deliver.
- Extract shared claim/deliver/recover mechanics only after behavior is correct.

**Tests.**

- worker delivery timeout does not duplicate timer delivery
- worker delivery timeout does not duplicate signal delivery
- immediate `signal_run/5` respects router concurrency and timeout settings

### 6.2 Internal module organization

#### Split `Fizz.Workflows`

Move private implementation in this order:

1. `Runtime.StepExecutions` for replay/read-model functions.
2. `Runtime.Timers` for timer row operations.
3. `Runtime.Signals` for signal row operations.
4. `Runtime.Runs` for start/wake/cancel/finalization/passivation helpers.
5. `Authoring` for definition/version CRUD and publish helpers.

`Fizz.Workflows` should delegate and remain the stable public context.

#### Narrow web coupling

- Add `Fizz.Workflows` facade functions for draft session operations used by LiveViews.
- Move `LiveVue.Encoder` derivation out of core workflow structs and into web payload/encoder modules.
- Make `WorkflowEditorLive` call `Fizz.Workflows` plus web payload helpers instead of internal workflow modules.

#### Split compiler assembly

- Move split/join/aggregator scope decisions into `Compiler.ScopePlanner`.
- Move runtime callback helpers into `Compiler.RuntimeCallbacks`.
- Make `ConnectionPlan` emit the indexes `Assembler` actually consumes, then delete unused plan fields.
- Move switch branch matching into the switch executor module and reuse it from assembly/runtime helpers.
- Expose one expression detection/access-plan helper from `Expressions` and remove duplicate local versions.

### 6.3 Smaller cleanup

- Extract embed validators for UUID and map fields.
- Split broad runtime changesets into create/claim/release/transition/terminal changesets.
- Add the foreign key from `workflow_run_leases.run_id` to `workflow_runs.id`.
- Fix the signal-claims migration rollback by normalizing `delivering` rows before restoring the old check constraint.
- Consolidate duplicate workflow test fixtures.

---

## 7. Implementation Order

### Phase 0 - Characterization tests

1. Add tests for stale `save_fact/3`.
2. Add tests for expired-lease checkpoint/fact rejection.
3. Add tests for active worker not passivated.
4. Add tests for timer/signal delivery timeout behavior.
5. Add tests around compiler switch routing and split/join semantics before moving compiler code.

Exit criteria: new tests fail for the known gaps and pass for existing intended behavior.

### Phase 1 - Ownership and persistence safety

1. Implement fenced SQLite write helper.
2. Apply it to checkpoint and fact writes.
3. Add lease-expiry validation to fence authorization.
4. Revisit `facts` conflict behavior.
5. Add lease FK migration.

Exit criteria: stale/expired owners cannot mutate checkpoint or fact state.

### Phase 2 - Runtime lifecycle safety

1. Add worker idleness/passivation API.
2. Update `PassivationSweeper` to require worker idleness.
3. Preserve local SQLite files when WAL checkpoint fails.
4. Centralize terminal finalization.
5. Ensure abnormal termination releases/stops renewing leases.

Exit criteria: active work is not passivated, and all terminal paths perform the same cleanup.

### Phase 3 - Delivery semantics

1. Add bounded worker delivery API.
2. Update `TimerPoller` to handle timeout/claim release explicitly.
3. Update `SignalRouter` to use the same bounded delivery contract.
4. Route immediate signal delivery through the same router path or make it durable-accept-only.
5. Extract shared delivery mechanics if the timer/signal code is clearly the same after behavior is settled.

Exit criteria: timeout paths are deterministic and covered by tests.

### Phase 4 - Split internal runtime modules

1. Extract `Runtime.StepExecutions`.
2. Extract `Runtime.Timers`.
3. Extract `Runtime.Signals`.
4. Extract `Runtime.Runs`.
5. Keep delegating from `Fizz.Workflows`.

Exit criteria: `Fizz.Workflows` is mostly facade, and public call sites do not change.

### Phase 5 - Editor/domain boundary

1. Add `Fizz.Workflows` draft facade functions.
2. Move LiveVue encoding out of core workflow modules.
3. Reduce `WorkflowEditorLive` aliases to the context facade and web payload modules.
4. Consolidate editor/workflow fixtures used by tests.

Exit criteria: web code no longer imports draft-session internals for normal workflows.

### Phase 6 - Compiler cleanup

1. Extract `Compiler.ScopePlanner`.
2. Extract `Compiler.RuntimeCallbacks`.
3. Consolidate connection indexes in `ConnectionPlan`.
4. Move switch matching to one source-of-truth module.
5. Consolidate expression/access-plan helpers.

Exit criteria: assembler behavior is unchanged, semantics tests pass, and new compiler files have narrow responsibilities.

### Phase 7 - Spec and plan cleanup

1. Update the spec files listed in Section 5.
2. Update stale exception blocks to reflect implemented behavior.
3. Mark this plan `Implemented` when all phases land.

Exit criteria: docs match code and no longer describe implemented guarantees as pending.

---

## 8. Testing Strategy

- Use focused regression tests for ownership, passivation, delivery, and migration behavior.
- Keep compiler refactors behind existing compiler semantics tests and add only missing characterization cases.
- Prefer tests against public context/runtime interfaces where possible.
- Use `start_supervised!/1` for process tests.
- Avoid `Process.sleep/1`; use monitors, `:sys.get_state/1`, or explicit synchronous APIs to coordinate.
- Run targeted tests for each phase, then `mix precommit` before merging.

Suggested targeted commands:

```bash
mix test test/fizz/workflows/store/sqlite_store_test.exs
mix test test/fizz/workflows/passivation_sweeper_test.exs
mix test test/fizz/workflows/timer_poller_test.exs
mix test test/fizz/workflows/signal_router_test.exs
mix test test/fizz/workflows/runner/worker_test.exs test/fizz/workflows/runner/worker_failure_test.exs
mix test test/fizz/workflows/compiler_test.exs test/fizz/workflows/compiler_semantics_test.exs
mix precommit
```

---

## 9. Migration / Rollback

Most phases are internal refactors and can roll back by reverting the PR.

Database migration phases need explicit rollback checks:

- lease FK migration must account for existing orphan rows before adding the constraint
- signal-claim rollback must normalize `delivering` rows before restoring the old status check
- any change to fact conflict behavior should be covered by a compatibility test with existing SQLite files

---

## 10. Risks & Open Questions

### 10.1 Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Fencing changes reveal latent stale-owner behavior in tests or dev workflows. | Medium | High | Add focused tests first and make errors explicit. |
| Centralized finalization changes lifecycle timing or broadcasts. | Medium | Medium | Characterize current terminal events before refactor. |
| Bounded delivery timeout policy is chosen incorrectly. | Medium | High | Decide the acknowledgement contract before implementation and test late-reply behavior. |
| Splitting `Fizz.Workflows` creates churn without reducing complexity. | Low | Medium | Move cohesive private sections only; keep facade stable. |
| Compiler extraction breaks subtle split/join semantics. | Medium | High | Refactor after semantics tests are green and avoid behavior changes in extraction PRs. |

### 10.2 Open questions

- **Should fact hash conflicts be immutable?** If fact hashes are content-addressed, `ON CONFLICT DO UPDATE` is unnecessary and risky. Confirm Runic hash semantics before changing it.
- **Should terminal run status updates be fenced?** The safest model is owner-only terminalization for active runs, but operator cancellation may need a separate authorized path.
- **What is the timer/signal delivery timeout contract?** Pick between release-and-retry, delivery-token acknowledgement, or a stricter no-timeout worker call with poller backpressure.
- **How much facade compatibility do web modules need during migration?** We can add facade functions first, then migrate LiveViews gradually.

---

## 11. Appendix - Review Inputs

This plan synthesizes the workflow module review performed on 2026-05-28:

- compiler/expression review
- runner/OTP review
- Ecto/persistence review
- holistic architecture review
- local code-quality and compile checks

The local compile check passed with:

```bash
mix compile --warnings-as-errors
```
