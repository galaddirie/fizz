# Workflow Runtime Timer and Signal Delivery Semantics Plan

Status date: 2026-05-28

## Goal

Make timer and signal delivery bounded, explicit, and recoverable without duplicate late deliveries caused by timed-out worker calls.

## Non-Goals

- Do not guarantee signal ordering beyond the existing spec.
- Do not change signal idempotency scope from `(run_id, signal_id)`.
- Do not introduce a generic delivery framework before timer and signal semantics are correct.
- Do not change Runic's in-process scheduler responsibilities.

## Spec Updates

Update:

- `docs/spec/specs/workflow-durable-timers.spec.md`
- `docs/spec/specs/workflow-signal-delivery.spec.md`
- `docs/spec/specs/workflow-run-lifecycle.spec.md`

Key scenarios:

- `workflows.durable_timers.delivery_timeout_releases_claim`
- `workflows.durable_timers.late_ack_does_not_redeliver`
- `workflows.signal_delivery.delivery_timeout_releases_claim`
- `workflows.signal_delivery.accept_does_not_bypass_router_limits`
- `workflows.signal_delivery.late_ack_does_not_redeliver`

## Delivery Contract Decision

Pick one contract before implementation:

| Option | Behavior | Tradeoff |
|---|---|---|
| Release and retry before acceptance | Timeout releases claim only if the worker has not accepted the event. | Simple, but requires a bounded accept API. |
| Delivery token | Claim remains in-flight until the worker acknowledges with a token. | More state, strongest late-ack handling. |
| Explicit failed/skipped | Timeout moves row to failed/skipped and requires operator or retry policy to move it. | Clear state, but may reduce automatic recovery. |

Recommended first implementation: bounded accept plus release-and-retry. If the worker has accepted the event, it must synchronously or token-ack settle the row before the claim can be recovered.

## Plan

### Phase 1 - Characterization

Add tests for:

- worker call timeout on timer delivery
- worker call timeout on signal delivery
- late successful worker processing after caller timeout
- immediate signal acceptance compared with router drain delivery

Exit criteria: current ambiguity around late success and redelivery is visible.

### Phase 2 - Bounded Worker Delivery

Add a worker API that has a finite timeout and clear result shape:

```elixir
{:ok, :accepted}
{:ok, :settled}
{:ok, :skipped}
{:error, :timeout}
{:error, reason}
```

The exact shape can differ, but it must distinguish "worker never accepted the event" from "worker accepted and settlement is now its responsibility."

Exit criteria: pollers no longer wrap an unbounded `GenServer.call(..., :infinity)` inside a timed task.

### Phase 3 - Timer Poller Settlement

Update `TimerPoller`:

- claim due timer rows
- deliver through the bounded API
- mark FIRED only after accepted and processed delivery
- release only when retry is safe
- never rely on stale claim recovery for normal timeout handling

Exit criteria: timeout handling is deterministic and tested.

### Phase 4 - Signal Router Settlement

Update `SignalRouter`:

- claim signal rows before delivery
- deliver through the bounded API
- mark DELIVERED or SKIPPED only after explicit outcome
- release only when retry is safe
- keep idempotency anchored to the inbox row

Exit criteria: signal timeout handling matches the selected contract.

### Phase 5 - Immediate Acceptance Alignment

Change `signal_run/5` and `SignalRouter.accept_signal/5` so immediate delivery either:

- routes through the same GenServer drain path with the same concurrency and timeout settings, or
- returns after durable insert and leaves delivery to drain/poll.

Exit criteria: immediate signal submission cannot bypass router limits.

### Phase 6 - Optional Shared Delivery Module

Only after timer and signal behavior is correct, extract shared claim/deliver/settle mechanics into `Fizz.Workflows.Runtime.Delivery` if the code is actually the same.

Exit criteria: shared code removes meaningful duplication without hiding domain-specific states.

## Acceptance Criteria

- Worker delivery calls cannot block pollers indefinitely.
- Timeout behavior is deterministic and covered by tests.
- A late successful worker reply cannot cause duplicate timer or signal delivery.
- Immediate signal submission follows the same delivery limits as drained delivery or is durable-accept-only.
- Specs describe the implemented acknowledgement contract.

## Test Commands

```bash
mix test test/fizz/workflows/timer_poller_test.exs
mix test test/fizz/workflows/signal_router_test.exs
mix test test/fizz/workflows/runner/worker_test.exs
mix precommit
```

## Rollout / Rollback

Roll out after lifecycle safety. If a migration adds delivery statuses or tokens, rollback must normalize rows back to statuses allowed by the old check constraints before reverting code.

## Dependencies

- Stable worker delivery API.
- Current timer and signal claim schemas.
- Decision on timeout acknowledgement semantics.

