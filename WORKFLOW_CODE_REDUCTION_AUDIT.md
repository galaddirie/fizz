# Workflow Code Reduction Audit

Scope: `lib/fizz/workflows/`

Goal: aggressively reduce workflow code while preserving functional behavior for callers.
Legacy API shape, internal module boundaries, and implementation structure are not protected.

## Plan

- Stage 0: map files, tests, supervision, and baseline quality metrics.
- Stage 1: parallel discovery agents inventory features, behavior, edge cases, and runtime outcomes.
- Stage 2: judge each inventory item as KEEP, KILL, or MERGE.
- Stage 3: writer/reviewer loops propose and accept reductions against the Stage 1 behavior inventory.
- Stage 4: apply accepted reductions and verify with focused tests plus `mix precommit`.

## Status

| Item | Status | Notes |
| --- | --- | --- |
| Stage 0 baseline | done | 14,368 LoC under `lib/fizz/workflows/`; baseline code-quality run completed and found workflow duplication/dead helper candidates. |
| Stage 1 discovery | done | Agents completed: A authoring/drafts/compiler, B runtime/runner/signals/timers, C persistence/store/leases, D cross-cutting quality/defensive behavior. |
| Stage 2 judgment | done | Judge marked high-confidence first slice: kill `Drafts`, kill `SqliteStore` GenServer wrapper, kill unused `LeaseManager.list_expired/1`, merge store opts, merge embed validators, replace exception-driven status normalization. |
| Stage 3 refactor loop | done | First slice committed; second slice for durable timer/signal row handling implemented and reviewer-approved. |
| Verification | done | First and second slices passed workflow-focused tests and full `mix precommit`. |

## Baseline Notes

- Workflow supervision lives in `Fizz.Application`:
  - `Fizz.Workflows.LeaseManager`
  - `Fizz.Workflows.Store.LitestreamManager`
  - `Fizz.Workflows.Runner.RunnableDispatcher`
  - `Fizz.Workflows.Runner.RunnableConsumerSupervisor`
  - `Fizz.Workflows.Runner.WorkerSupervisor`
  - `Fizz.Workflows.TimerPoller`
  - `Fizz.Workflows.SignalRouter`
  - `Fizz.Workflows.PassivationSweeper`
  - `Fizz.Workflows.DraftSessionSupervisor` and `Fizz.Workflows.DraftSessionRegistry`
- Largest files:
  - `DraftSession.Operation`: 1,496 LoC
  - `Runner.Worker`: 1,445 LoC
  - `Compiler.Assembler`: 1,328 LoC
  - `DraftSession`: 970 LoC
  - `Runtime.Runs`: 699 LoC
- Baseline `run_analysis.sh` exited non-zero because it reports existing quality findings. Workflow-specific candidates include repeated GenServer boilerplate, repeated timer/signal runtime operations, and unused private helpers in `StepError` and `WorkflowRun`.
- Workflow-only code-quality scan found 86 issues across 27 files before changes.
- Post-first-slice workflow-only code-quality scan found 76 issues across 23 files.
- Post-second-slice workflow-only code-quality scan found 73 issues across 24 files. The new helper triggers a false positive for `claim_row!/5` because the analyzer reports bang predicates without punctuation.
- Let-it-crash candidate harvest scanned 60 workflow files. High-signal buckets: 8 rescue clauses, 4 catch clauses, 7 try blocks, 81 catch-all clauses.

## Stage 1 Inventory

Reconciled inventory:

- Authoring and versioning:
  - Project-scoped creation of workflow definitions and first draft versions.
  - Draft-only save and publish operations.
  - Published version cloning back into a new draft.
  - Archive/list/get definitions within the current project scope.
  - Publish-time validation, credential default normalization, compiled hash generation, and trigger registration sync.
  - Save is intentionally more permissive than publish; publish adds entry-step, config, expression, credential, compiled hash, timestamp, and publishing-user checks.
- Draft sessions:
  - One dynamic GenServer per draft version, registry-backed by version id.
  - Join/leave, idle shutdown, dirty persistence, debounce/retry, undo/redo stacks per user, revision preview, snapshots.
  - Editor-only output pinning and step enable/disable state.
  - Structural operation application for steps, connections, groups, revisions, and layout.
  - Visible broadcasts include `:save_status`, `:draft_updated`, `:draft_persisted`, `:operation_rejected`, and `:editor_state_changed`.
  - Operation edge cases include string/atom operation names, string/atom params, UUID validation, connection self/duplicate rejection, handle compatibility/cardinality checks, auto-connect behavior, group relative/absolute positioning, idempotent disable, and drag transaction acknowledgements.
- Compiler:
  - Normalizes snapshots, validates connection semantics, plans scopes, compiles expressions, assembles Runic workflows, and builds runtime callbacks.
  - Preserves step output selection, splitter/join/aggregator/switch behavior, credential refs, and runtime context resolution.
  - Deterministic hash excludes UI-only edits and includes execution-relevant steps/config/connections.
- Runtime and runner:
  - Start/list/get/cancel runs, start or wake workers, acquire leases, initialize SQLite stores, compile and load workflow state.
  - Worker owns single-writer Runic state, dispatch, checkpointing, active task tracking, local and durable timers, retries, passivation, terminal completion/failure, and PubSub run/step events.
  - Global runnable dispatcher provides demand-based, fair per-run queueing; consumers execute one runnable at a time through a task supervisor.
- Durable timers and signals:
  - Create pending rows, claim with row locks, recover stale claims, release claims, mark terminal states, and route delivery to workers.
  - Timer poller and signal router are structurally similar and are strong MERGE candidates.
- Persistence/store/leases:
  - PostgreSQL lease rows fence SQLite checkpoint writes.
  - SQLite store saves compressed Runic logs and fact blobs, deduplicates facts by hash, detects hash conflicts, migrates local DBs, and WAL-checkpoints.
  - Passivation stops idle workers, verifies DB-only sleeping runs, optionally evicts local SQLite files when Litestream is running, marks runs passivated, and releases leases.
  - Rehydration acquires a fresh lease, restores from S3 if local SQLite is missing, loads the SQLite checkpoint, rebuilds Runic state, and starts a worker.
  - Reads are not fenced; writes are fenced.

## Stage 1 Reduction Candidates

- MERGE candidate: durable timer/signal repositories and poller/router loops.
- KILL/MERGE candidate: `Fizz.Workflows.Drafts` facade; public `Fizz.Workflows` draft behavior must stay.
- MERGE candidate: repeated embed validators for UUID/map fields.
- KILL candidate: unused `SqliteStore` GenServer wrapper (`use GenServer`, `start_link/1`, `child_spec/1`, callback `init/1`) if no behavior depends on starting it.
- KILL candidate: `LeaseManager.list_expired/1` if only tests call it.
- MERGE candidate: `store_opts/3` duplicated in `Runtime.Runs` and `Runtime.StepExecutions`.
- MERGE candidate: repeated GenServer `start_link`, `child_spec`, scheduling, call timeout, and `server_name` helpers.
- MERGE candidate: live PubSub step payload and step-execution rehydration projection.
- REWRITE candidate: `DraftSession.Operation` around shared primitives.
- MERGE candidate: draft-time and compile-time connection handle validation.
- MERGE candidate: `WorkflowDefinitionVersion`, `DraftValidator`, and `PublishValidation` validation issue production.
- REWRITE candidate: `Compiler.Assembler` branch/function pairs.
- REWRITE candidate: `Runner.Worker` lifecycle phases.
- DEFER candidate: legacy `ExecutionContext`/expression map compatibility until downstream executors are standardized.
- DEFENSIVE candidate: broad compiler rescue in `Assembler`, broad task-start rescue in `RunnableConsumer`, exception-driven status normalization.

## Stage 2 Judgment

- KEEP core authoring, draft session, compiler, runtime, worker, dispatcher, durable timer/signal, lease fencing, SQLite replay, passivation, and rehydration behavior.
- KILL `Fizz.Workflows.Drafts` facade while preserving top-level `Fizz.Workflows.*draft*` outcomes.
- KILL `SqliteStore` GenServer wrapper; keep Runic store callbacks and direct functions.
- KILL `LeaseManager.list_expired/1`; no production callers.
- MERGE `store_opts/3`.
- MERGE embedded UUID/map/list validators.
- KILL exception-driven status normalization.
- DEFER worker lifecycle rewrite, compiler assembler rewrite, operation rewrite, live/replay projection merge, execution-context legacy compatibility cuts, and runnable consumer rescue changes.

## Stage 3 Accepted Refactors

- First slice done:
  - `Fizz.Workflows` delegates draft calls directly to `DraftSession` / `DraftSession.Operation`.
  - Delete `Fizz.Workflows.Drafts`.
  - Remove unused `SqliteStore` process scaffolding.
  - Remove unused `LeaseManager.list_expired/1` and related private code.
  - Add shared embed validation helper.
  - Add shared workflow store options helper.
  - Replace status normalization rescue with explicit lookup.

Reviewer result: PASS. The reviewer checked the dirty diff only against the Stage 1 behavior inventory and found no functional regression for the accepted Stage 2 cuts.

Measured reduction:

- `lib/fizz/workflows/` LoC: 14,368 -> 14,172.
- Tracked diff: 50 insertions, 297 deletions across 10 tracked files, plus two new small helper modules and this audit file.

Verification:

- `mix compile --warnings-as-errors`: passed.
- Focused reviewer tests: 88 tests, 0 failures.
- Workflow-focused suite: `mix test test/fizz/workflows test/fizz/workflows_test.exs test/runic/workflow_log_rehydration_test.exs` passed with 204 tests, 0 failures.
- Project precommit: `mix precommit` passed with 558 tests, 0 failures.
- `git diff --check`: passed.

- Second slice done:
  - Added `Fizz.Workflows.Runtime.DurableRows` for shared durable row claim/recover/release/get/update mechanics.
  - Kept timer and signal creation paths domain-specific.
  - Kept `TimerPoller` and `SignalRouter` delivery orchestration separate.
  - Preserved timer-specific semantics: due-row filtering, `fire_at` ordering, batch `FOR UPDATE SKIP LOCKED`, explicit `FOR UPDATE`, `:firing` recovery/release, and idempotent `mark_timer_fired/1`.
  - Preserved signal-specific semantics: `inserted_at` ordering, batch and explicit `FOR UPDATE SKIP LOCKED`, `:delivering` recovery/release, and delivered/skipped claim clearing.

Second-slice reviewer result: PASS. The reviewer checked the dirty diff only against the Stage 1 timer/signal behavior inventory and found no behavior regression.

Second-slice measured reduction:

- `lib/fizz/workflows/` LoC: 14,172 -> 14,117.
- Dirty diff after first commit: `runtime/signals.ex` and `runtime/timers.ex` reduced by 198 tracked deletions and 51 tracked insertions, plus one new small helper module.

Second-slice verification so far:

- `mix compile --warnings-as-errors`: passed.
- Focused runtime tests: `mix test test/fizz/workflows/timer_poller_test.exs test/fizz/workflows/signal_router_test.exs test/fizz/workflows/runner/worker_test.exs test/fizz/workflows/runner/worker_failure_test.exs` passed with 34 tests, 0 failures.
- Workflow-focused suite: `mix test test/fizz/workflows test/fizz/workflows_test.exs test/runic/workflow_log_rehydration_test.exs` passed with 204 tests, 0 failures.
- Project precommit: `mix precommit` passed with 558 tests, 0 failures.

## Decisions

- Preserve functional behavior only: visible outcomes, persistence semantics, run lifecycle, editor/draft behavior, timers/signals, and execution outcomes.
- Do not preserve bad internal APIs or module boundaries for their own sake.
- Prefer deletion or merge when a behavior is duplicated or only exists to defend old structure.

## Open Questions

- None for the accepted first slice.

## Deferred Cuts

- Timer/signal repository and poller/router merge: strong reduction candidate, but requires a dedicated writer/reviewer loop because it changes durable delivery orchestration.
- `DraftSession.Operation` rewrite around shared primitives: high payoff, high risk; preserve the Stage 1 operation edge cases if attempted.
- `Compiler.Assembler` rewrite: high payoff, high risk; preserve deterministic hash behavior, branch semantics, credential dependencies, and runtime callback behavior.
- `Runner.Worker` lifecycle rewrite: high payoff, high risk; preserve single-writer store ownership, checkpointing, retry, passivation, and PubSub outcomes.
- Live PubSub step payload / rehydration projection merge: likely safe if tests lock outcome shape first.
- ExecutionContext compatibility cuts: wait until downstream executor usage is standardized.
