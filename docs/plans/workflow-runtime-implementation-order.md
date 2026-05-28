# Workflow Runtime Maintainability Refactor - Implementation Order

Status date: 2026-05-28

## Ordering Principle

Correctness-sensitive runtime safety lands before module extraction. Extraction PRs should be behavior-preserving and easy to revert.

This follows the repo's Spec Led pattern: specs hold current-truth contracts and explicit exceptions; plans hold rollout sequencing and implementation detail.

## Phase 0 - Characterization

Add or tighten tests before changing behavior.

Scope:

- stale fact writes
- expired lease checkpoint and fact writes
- active work passivation
- sleeping run passivation with checkpoint
- WAL checkpoint failure file preservation
- timer delivery timeout
- signal delivery timeout
- late acknowledgement after delivery timeout
- immediate signal acceptance compared with router drain
- switch routing and split/join compiler semantics

Exit criteria:

- known gaps are visible in focused tests
- existing intended behavior remains covered

## Phase 1 - Ownership and Storage Safety

Plan file: `docs/plans/workflow-runtime-ownership-storage-safety.md`

Implement:

- one fenced write helper in `SqliteStore`
- lease-expiry validation in fence authorization
- fenced standalone fact writes
- explicit fact hash conflict behavior
- lease FK migration, if orphan handling is settled

Exit criteria:

- stale or expired owners cannot mutate per-run SQLite state
- current owners can still checkpoint and persist facts

## Phase 2 - Lifecycle and Passivation Safety

Plan file: `docs/plans/workflow-runtime-lifecycle-passivation.md`

Implement:

- worker idleness/passivation API
- passivation candidate handling that treats `last_active_at` as a filter only
- DB-only passivation guard for sleeping checkpointed runs
- WAL checkpoint failure file preservation
- centralized terminal finalization

Exit criteria:

- active work is not passivated
- terminal cleanup is consistent across completion, failure, cancellation, and abnormal termination

## Phase 3 - Timer and Signal Delivery

Plan file: `docs/plans/workflow-runtime-delivery-semantics.md`

Implement:

- selected timeout acknowledgement contract
- bounded worker delivery API
- timer claim settlement under timeout and late acknowledgement
- signal claim settlement under timeout and late acknowledgement
- immediate signal acceptance alignment with router delivery limits

Exit criteria:

- delivery timeout behavior is deterministic
- late acknowledgement cannot create duplicate logical delivery

## Phase 4 - Internal Runtime Boundaries

Plan file: `docs/plans/workflow-runtime-internal-boundaries.md`

Extract:

- `Runtime.StepExecutions`
- `Runtime.Timers`
- `Runtime.Signals`
- `Runtime.Runs`
- `Runtime.Delivery`, only if timer and signal delivery logic converges
- `Authoring`

Exit criteria:

- `Fizz.Workflows` remains the public facade
- runtime-private operations have narrow module ownership
- extraction PRs do not change behavior

## Phase 5 - Editor Boundary

Plan file: `docs/plans/workflow-runtime-editor-boundary.md`

Implement:

- draft-session facade functions
- web-owned payload/encoding modules
- LiveView migration to context facade plus web payload helpers
- fixture consolidation

Exit criteria:

- web code uses `Fizz.Workflows` for domain operations
- core workflow modules no longer carry web serialization concerns

## Phase 6 - Compiler Boundary

Plan file: `docs/plans/workflow-runtime-compiler-boundary.md`

Extract:

- `Compiler.ScopePlanner`
- `Compiler.RuntimeCallbacks`
- connection-plan indexes actually consumed by assembler
- switch matching source of truth
- expression/access-plan helper source of truth

Exit criteria:

- compiler behavior is unchanged
- semantic coverage remains green

## Phase 7 - Spec Reconciliation

After each implementation PR:

- update the relevant spec exception blocks
- add verification entries for new source or test files
- remove exceptions only when tests prove the guarantee
- update this implementation order if phases split or merge

Exit criteria:

- specs describe implemented guarantees accurately
- remaining gaps are explicit exceptions, not stale broad pending notes

## Global Test Gate

Run targeted tests per phase, then:

```bash
mix precommit
```

Local note: `mix precommit` requires working Postgres credentials for `Fizz.Repo`.

## Rollback Strategy

Prefer one PR per phase or subphase.

Code-only safety fixes and extractions roll back by revert. Migration phases require explicit down-migration validation, especially lease FK changes and signal claim status constraints.

