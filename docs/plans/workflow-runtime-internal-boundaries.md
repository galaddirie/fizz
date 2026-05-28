# Workflow Runtime Internal Boundary Plan

Status date: 2026-05-28

## Goal

Keep `Fizz.Workflows` as the public context facade while moving runtime implementation details into focused internal modules.

## Non-Goals

- Do not split the public workflow context.
- Do not move code only to reduce line count.
- Do not mix safety behavior changes with pure extraction PRs.
- Do not add generic abstractions where operation-specific modules are clearer.

## Target Shape

| Module | Responsibility |
|---|---|
| `Fizz.Workflows.Authoring` | Definition CRUD, draft/publish lifecycle, version lookup helpers. |
| `Fizz.Workflows.Runtime.Runs` | Start, wake, cancel, complete, fail, passivate, lease release, terminal cleanup. |
| `Fizz.Workflows.Runtime.Timers` | Timer create, claim, recover, release, mark, cancel row operations. |
| `Fizz.Workflows.Runtime.Signals` | Signal inbox create, claim, recover, release, mark row operations and idempotency. |
| `Fizz.Workflows.Runtime.StepExecutions` | Read-model projection from Runic events plus fact loading. |
| `Fizz.Workflows.Runtime.Delivery` | Shared bounded delivery pattern, if timer and signal code converges. |

## Plan

### Phase 1 - Step Execution Projection

Extract step execution replay/read-model helpers first because they are mostly read-side.

Exit criteria:

- one source of truth for step execution projection
- web/debug read paths call the same projection module
- no runtime behavior changes

### Phase 2 - Timer Operations

Move timer row operations from `Fizz.Workflows` into `Runtime.Timers`.

Keep public facade functions in `Fizz.Workflows` for compatibility.

Exit criteria:

- `claim_due_timers/1`, `claim_timer/2`, `recover_stale_timers/1`, `release_timer_claim/1`, `mark_timer_fired/1`, and timer cancellation are owned by one module
- timer tests pass without call-site churn outside the facade

### Phase 3 - Signal Operations

Move signal inbox row operations into `Runtime.Signals`.

Exit criteria:

- create, claim, recover, release, delivered, and skipped operations are owned by one module
- idempotency behavior remains anchored to `(run_id, signal_id)`

### Phase 4 - Run Operations

Move run start, wake, cancel, passivate, finalization, and lease-release helpers into `Runtime.Runs`.

Exit criteria:

- `Fizz.Workflows` delegates run orchestration
- finalization stays in one internal module
- public signatures remain stable

### Phase 5 - Authoring Operations

Move definition/version CRUD and publish helpers into `Authoring`.

Exit criteria:

- authoring code is separated from runtime lease, timer, signal, and worker concerns
- web and tests can still use `Fizz.Workflows`

## Acceptance Criteria

- Public call sites continue to use `Fizz.Workflows`.
- `Fizz.Workflows` has fewer `@doc false` runtime internals.
- Timer and signal row operations are not interleaved with unrelated context code.
- Extraction PRs do not change behavior.
- Tests are green after each extraction.

## Test Commands

```bash
mix test test/fizz/workflows_test.exs
mix test test/fizz/workflows/timer_poller_test.exs
mix test test/fizz/workflows/signal_router_test.exs
mix test test/fizz/workflows/runner/worker_test.exs
mix precommit
```

## Rollout / Rollback

Ship after safety fixes. Each extraction should be independently revertible. Keep delegating functions in `Fizz.Workflows` until every internal caller has moved and external call sites are audited.

## Dependencies

- Ownership and storage safety.
- Lifecycle and delivery behavior stabilized.
- Existing tests passing before extraction begins.

