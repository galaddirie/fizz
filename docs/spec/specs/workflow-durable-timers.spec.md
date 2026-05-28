# Workflow Durable Timers

This spec covers the durable timer lifecycle including creation from step
intents, the polling and firing model, cancellation semantics, and the boundary
between platform timers and in-process scheduling.

```spec-meta
id: workflows.durable_timers
kind: service
status: active
summary: Durable timers are platform-level Postgres rows created from workflow step intents, polled with skip-locked concurrency, and delivered as workflow input events after rehydrating dormant executions.
surface:
  - docs/plans/durable-workflow-system-design.md
  - docs/spec/decisions/durable-timer-model.md
  - docs/spec/decisions/postgres-control-plane.md
```

## Requirements

```spec-requirements
- id: workflows.durable_timers.state_machine
  statement: Durable timers follow the state machine PENDING to FIRING to FIRED or CANCELLED, with one recovery transition — FIRING to PENDING — that occurs when a poller claims a timer but fails to complete delivery within a bounded claim TTL. The poller records a `claimed_at` timestamp and `claimed_by` identifier when transitioning to FIRING; if the claim TTL expires without the timer reaching FIRED, any poller may reset it to PENDING for re-claim. This prevents stranded timers when a poller or worker crashes mid-delivery.
  priority: must
  stability: stable

- id: workflows.durable_timers.creation_from_intent
  statement: When a workflow step produces a `sleep` or `schedule_at` timer intent, the platform persists a `durable_timers` row in Postgres with the computed `fire_at` timestamp before the Worker passivates.
  priority: must
  stability: stable

- id: workflows.durable_timers.polling_skip_locked
  statement: Timer polling uses `FOR UPDATE SKIP LOCKED` so multiple poller instances can operate concurrently, each atomically claiming a disjoint batch of due timers without contention or double-firing.
  priority: must
  stability: stable

- id: workflows.durable_timers.listen_notify_optimization
  statement: LISTEN/NOTIFY may be used as a latency optimization for near-term timer delivery, but polling remains the authoritative catch-up mechanism for missed notifications and dormant-run wakeups.
  priority: should
  stability: stable

- id: workflows.durable_timers.cancellation_on_termination
  statement: When a workflow run reaches a terminal state, all PENDING timers associated with that run must transition to CANCELLED and future polling must skip them.
  priority: must
  stability: stable

- id: workflows.durable_timers.passivation_interaction
  statement: Long-duration timers trigger Worker passivation to free resources; when the timer fires, the platform must rehydrate the execution before delivering the TimerFired event as workflow input.
  priority: must
  stability: stable

- id: workflows.durable_timers.kernel_boundary
  statement: Runic SchedulerPolicy owns in-process timeouts, retry backoff, and deadline enforcement within running Workers; durable timers are exclusively a platform concern for workflow-level waits that must survive Worker shutdown.
  priority: must
  stability: stable

- id: workflows.durable_timers.bounded_delivery
  statement: Poller-to-worker timer delivery must use a bounded call with explicit timeout handling rather than relying on an unbounded worker call hidden inside the poller delivery task.
  priority: must
  stability: stable

- id: workflows.durable_timers.timeout_claim_resolution
  statement: A timer delivery timeout must settle the FIRING claim through an explicit durable contract: release the claim only when late success is impossible, retain an in-flight token until acknowledgement, or mark the delivery skipped or failed through an explicit transition. A single timer must not be processed late and then redelivered as new work after claim recovery.
  priority: must
  stability: draft
```

## Scenarios

```spec-scenarios
- id: workflows.durable_timers.sleep_and_fire
  given:
    - a workflow step produces a `sleep(1 hour)` intent
    - the timer row is persisted in Postgres and the Worker passivates
  when:
    - the poller detects the timer is due after one hour
  then:
    - the timer transitions from PENDING to FIRING
    - the workflow execution is rehydrated
    - a TimerFired event is delivered as workflow input
    - the timer transitions to FIRED after successful delivery
  covers:
    - workflows.durable_timers.state_machine
    - workflows.durable_timers.creation_from_intent
    - workflows.durable_timers.passivation_interaction

- id: workflows.durable_timers.cancel_on_workflow_termination
  given:
    - a workflow run has a PENDING timer
    - the run is cancelled by an operator
  when:
    - the cancellation completes and the run reaches terminal status
  then:
    - the timer transitions to CANCELLED
    - future poller scans skip the cancelled timer
  covers:
    - workflows.durable_timers.cancellation_on_termination
    - workflows.durable_timers.state_machine

- id: workflows.durable_timers.concurrent_poller_contention
  given:
    - multiple poller instances are scanning for due timers
    - several timers are due simultaneously
  when:
    - both pollers execute the `FOR UPDATE SKIP LOCKED` query
  then:
    - each poller claims a disjoint batch of timers
    - no timer is fired more than once
  covers:
    - workflows.durable_timers.polling_skip_locked

- id: workflows.durable_timers.short_timer_stays_hot
  given:
    - a workflow produces a short-duration timer under the passivation idle threshold
  when:
    - the timer is created
  then:
    - the Worker may remain HOT rather than passivating
    - the timer is delivered without requiring S3 download or rehydration
  covers:
    - workflows.durable_timers.passivation_interaction
    - workflows.durable_timers.kernel_boundary

- id: workflows.durable_timers.poller_crash_during_firing
  given:
    - a poller has claimed a timer and transitioned it to FIRING with a claim TTL
    - the poller crashes before completing delivery
  when:
    - the claim TTL expires and another poller scans for stale FIRING timers
  then:
    - the stale timer is reset to PENDING
    - a subsequent poll cycle re-claims and delivers the timer normally
    - the timer is not permanently stranded
  covers:
    - workflows.durable_timers.state_machine
    - workflows.durable_timers.polling_skip_locked

- id: workflows.durable_timers.delivery_timeout_releases_claim
  given:
    - a due timer is claimed and moved to FIRING
    - worker delivery times out before the worker accepts the event
  when:
    - the timeout handler runs under a release-and-retry delivery contract
  then:
    - the timer claim is released back to PENDING
    - claim metadata is cleared
    - no FIRED marker is written
    - a later poll may retry delivery
  covers:
    - workflows.durable_timers.bounded_delivery
    - workflows.durable_timers.timeout_claim_resolution

- id: workflows.durable_timers.late_ack_does_not_redeliver
  given:
    - a timer delivery call reaches the worker
    - the poller times out before it observes the worker acknowledgement
  when:
    - the worker later finishes processing the timer event
  then:
    - the durable timer row cannot also be recovered as a fresh PENDING timer for duplicate delivery
    - the timer reaches exactly one durable settlement state
  covers:
    - workflows.durable_timers.timeout_claim_resolution
```

## Verification

```spec-verification
- kind: doc_file
  target: spec/decisions/durable-timer-model.md
  covers:
    - workflows.durable_timers.state_machine
    - workflows.durable_timers.creation_from_intent
    - workflows.durable_timers.polling_skip_locked
    - workflows.durable_timers.listen_notify_optimization
    - workflows.durable_timers.cancellation_on_termination
    - workflows.durable_timers.passivation_interaction
    - workflows.durable_timers.kernel_boundary
    - workflows.durable_timers.sleep_and_fire
    - workflows.durable_timers.cancel_on_workflow_termination
    - workflows.durable_timers.concurrent_poller_contention
    - workflows.durable_timers.short_timer_stays_hot

- kind: doc_file
  target: docs/plans/durable-workflow-system-design.md
  covers:
    - workflows.durable_timers.creation_from_intent
    - workflows.durable_timers.polling_skip_locked
    - workflows.durable_timers.passivation_interaction
    - workflows.durable_timers.sleep_and_fire

- kind: doc_file
  target: spec/decisions/postgres-control-plane.md
  covers:
    - workflows.durable_timers.creation_from_intent
    - workflows.durable_timers.polling_skip_locked
    - workflows.durable_timers.cancellation_on_termination

- kind: source_file
  target: lib/fizz/workflows/timer_poller.ex
  covers:
    - workflows.durable_timers.state_machine
    - workflows.durable_timers.polling_skip_locked
    - workflows.durable_timers.bounded_delivery

- kind: source_file
  target: lib/fizz/workflows/runner/worker.ex
  covers:
    - workflows.durable_timers.passivation_interaction
    - workflows.durable_timers.timeout_claim_resolution

- kind: test_file
  target: test/fizz/workflows/timer_poller_test.exs
  covers:
    - workflows.durable_timers.sleep_and_fire
    - workflows.durable_timers.cancel_on_workflow_termination
    - workflows.durable_timers.concurrent_poller_contention
    - workflows.durable_timers.poller_crash_during_firing
    - workflows.durable_timers.delivery_timeout_releases_claim
    - workflows.durable_timers.late_ack_does_not_redeliver
```
