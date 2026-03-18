# Workflow Activity Dispatch

This spec covers the activity dispatch lifecycle, scheduler policy configuration,
durable event tracking, pluggable executors, crash recovery of in-flight work,
and backpressure mechanics.

```spec-meta
id: workflows.activity_dispatch
kind: runtime
status: active
summary: Activities flow through a plan-prepare-schedule-dispatch-apply cycle with per-activity retry policies, durable event tracking for crash recovery, pluggable executors, and backpressure gates at worker and node levels.
surface:
  - docs/plans/durable-workflow-system-design.md
  - docs/plans/runic-research.md
  - .spec/decisions/runic-as-execution-kernel.md
```

## Requirements

```spec-requirements
- id: workflows.activity_dispatch.dispatch_flow
  statement: Activity execution follows the plan, prepare, schedule, dispatch, apply cycle owned by the Runic Runner Worker, where each phase has a defined responsibility and the apply phase is the single state-advancement boundary.
  priority: must
  stability: stable

- id: workflows.activity_dispatch.scheduler_policy
  statement: Per-activity retry count, backoff strategy (exponential, linear), base delay, timeout, and execution mode are configured via SchedulerPolicy matchers, allowing different reliability profiles per step type.
  priority: must
  stability: stable

- id: workflows.activity_dispatch.durable_mode_events
  statement: Activities with `execution_mode: :durable` emit RunnableDispatched, RunnableCompleted, and RunnableFailed events into the workflow log, enabling crash recovery to identify and re-dispatch interrupted work.
  priority: must
  stability: stable

- id: workflows.activity_dispatch.pluggable_executors
  statement: Dispatch uses pluggable Executor implementations — Task (async via Task.Supervisor), inline (synchronous for sub-millisecond work), and GenStage (backpressure-aware) — selectable per component via SchedulerPolicy.
  priority: must
  stability: stable

- id: workflows.activity_dispatch.recovery_pending
  statement: On recovery, `Workflow.pending_runnables/1` identifies runnables that were dispatched but not yet durably completed, enabling the platform to re-dispatch interrupted work with the same stable runnable identity.
  priority: must
  stability: stable

- id: workflows.activity_dispatch.on_failure_semantics
  statement: When retry attempts are exhausted, `on_failure: :skip` allows the workflow to continue past the failed activity with a skip marker, while `on_failure: :fail` (default) transitions the workflow to a failed state.
  priority: must
  stability: stable

- id: workflows.activity_dispatch.backpressure
  statement: Worker-level `max_concurrency` gates how many runnables are dispatched simultaneously per execution, and node-level `max_children` on the DynamicSupervisor caps total active Workers across the node.
  priority: must
  stability: stable
```

## Scenarios

```spec-scenarios
- id: workflows.activity_dispatch.retry_with_backoff
  given:
    - an activity is configured with `max_retries: 3` and `backoff: :exponential`
  when:
    - the first attempt fails with a transient error
  then:
    - the PolicyDriver retries with increasing delay between attempts
    - each retry uses the same stable runnable identity
    - if a subsequent attempt succeeds, the workflow continues normally
  covers:
    - workflows.activity_dispatch.scheduler_policy
    - workflows.activity_dispatch.dispatch_flow

- id: workflows.activity_dispatch.skip_on_failure
  given:
    - an activity is configured with `on_failure: :skip` and `max_retries: 2`
  when:
    - all retry attempts are exhausted
  then:
    - the activity is marked as skipped in the workflow state
    - the workflow continues past the failed activity
    - downstream steps receive a skip indicator rather than output data
  covers:
    - workflows.activity_dispatch.on_failure_semantics
    - workflows.activity_dispatch.scheduler_policy

- id: workflows.activity_dispatch.crash_recovery_redispatch
  given:
    - a durable-mode activity was dispatched and a RunnableDispatched event was logged
    - the Worker crashes before the completion event is recorded
  when:
    - the workflow is restored from checkpoint
  then:
    - `pending_runnables/1` identifies the activity as in-flight
    - the platform re-dispatches it with the same runnable identity for external idempotency
  covers:
    - workflows.activity_dispatch.durable_mode_events
    - workflows.activity_dispatch.recovery_pending

- id: workflows.activity_dispatch.parallel_fan_out
  given:
    - a workflow DAG has multiple steps whose input facts are simultaneously satisfied
  when:
    - `prepare_for_dispatch` extracts all ready runnables
  then:
    - all ready runnables are dispatched concurrently up to `max_concurrency`
    - each applies independently as results return
  covers:
    - workflows.activity_dispatch.dispatch_flow
    - workflows.activity_dispatch.backpressure

- id: workflows.activity_dispatch.backpressure_throttle
  given:
    - the Worker has reached `max_concurrency` in-flight tasks
  when:
    - additional runnables become ready for dispatch
  then:
    - dispatch is deferred until in-flight slots free up
    - the workflow continues applying completed results while waiting
  covers:
    - workflows.activity_dispatch.backpressure
```

## Verification

```spec-verification
- kind: doc_file
  target: docs/plans/durable-workflow-system-design.md
  covers:
    - workflows.activity_dispatch.dispatch_flow
    - workflows.activity_dispatch.scheduler_policy
    - workflows.activity_dispatch.durable_mode_events
    - workflows.activity_dispatch.pluggable_executors
    - workflows.activity_dispatch.recovery_pending
    - workflows.activity_dispatch.on_failure_semantics
    - workflows.activity_dispatch.backpressure
    - workflows.activity_dispatch.retry_with_backoff
    - workflows.activity_dispatch.crash_recovery_redispatch
    - workflows.activity_dispatch.parallel_fan_out
    - workflows.activity_dispatch.backpressure_throttle

- kind: doc_file
  target: docs/plans/runic-research.md
  covers:
    - workflows.activity_dispatch.dispatch_flow
    - workflows.activity_dispatch.pluggable_executors
    - workflows.activity_dispatch.recovery_pending
    - workflows.activity_dispatch.crash_recovery_redispatch

- kind: doc_file
  target: .spec/decisions/runic-as-execution-kernel.md
  covers:
    - workflows.activity_dispatch.dispatch_flow
    - workflows.activity_dispatch.scheduler_policy
    - workflows.activity_dispatch.pluggable_executors
```

## Exceptions

```spec-exceptions
- id: workflows.activity_dispatch.impl_pending
  note: The repository does not yet contain the platform Store adapter wiring, SchedulerPolicy configuration from authored definitions, or skip/fail semantics enforcement that would verify these dispatch contracts in code.
  relates_to:
    - workflows.activity_dispatch.durable_mode_events
    - workflows.activity_dispatch.recovery_pending
    - workflows.activity_dispatch.on_failure_semantics
    - workflows.activity_dispatch.backpressure
```
