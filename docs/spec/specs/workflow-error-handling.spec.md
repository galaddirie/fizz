# Workflow Error Handling

This spec covers step-level error and skip semantics, workflow-level failure
states, the documented failure mitigation table, and the v1 boundary on
compensation and rollback.

```spec-meta
id: workflows.error_handling
kind: policy
status: active
summary: Step errors trigger configurable retry policies before escalating to workflow failure, infrastructure failures are mitigated through leasing, fencing, and replication, and v1 relies on idempotency at service boundaries rather than compensation or rollback.
surface:
  - docs/plans/durable-workflow-system-design.md
  - docs/plans/runic-research.md
```

## Requirements

```spec-requirements
- id: workflows.error_handling.step_error_triggers_retry
  statement: A step returning `{:error, reason}` triggers the configured retry policy, which applies backoff and re-dispatches the activity up to the maximum retry count before considering the step failed.
  priority: must
  stability: stable

- id: workflows.error_handling.step_skip
  statement: A step returning `{:skip, reason}`, or a step that exhausts retries with `on_failure: :skip` configured, allows the workflow to continue with the step marked as skipped rather than halting execution.
  priority: must
  stability: stable

- id: workflows.error_handling.workflow_failure_state
  statement: A workflow transitions to FAILED when a critical step exhausts its retry policy with `on_failure: :fail` and no fallback is configured, making the run terminal.
  priority: must
  stability: stable

- id: workflows.error_handling.failure_mitigation_table
  statement: The platform documents and mitigates expected failure modes including worker process crash (supervisor restart plus checkpoint restore), node failure (lease expiry plus failover), split-brain (fencing token rejection), Postgres outage (in-flight step completes but no new steps dispatch, lease renewal and fence validation suspend, execution is paused until Postgres recovers), S3 outage (passivation retries with backoff), SQLite corruption (Litestream replica recovery), activity timeout (PolicyDriver enforcement), and schema incompatibility (migration-on-wake).
  priority: must
  stability: stable

- id: workflows.error_handling.no_compensation_v1
  statement: v1 does not support automatic compensation or rollback of completed steps; workflows that need undo logic must implement it as explicit forward steps in the authored graph.
  priority: must
  stability: stable

- id: workflows.error_handling.idempotency_at_boundary
  statement: Recovery from crashes relies on at-least-once activity dispatch combined with external idempotency contracts at service boundaries, rather than transactional rollback of remote side effects.
  priority: must
  stability: stable
```

## Scenarios

```spec-scenarios
- id: workflows.error_handling.retry_then_fail
  given:
    - a step is configured with `max_retries: 3` and `on_failure: :fail`
  when:
    - all retry attempts return errors
  then:
    - the step is marked as failed after exhausting retries
    - the workflow transitions to FAILED
    - no further steps are dispatched
  covers:
    - workflows.error_handling.step_error_triggers_retry
    - workflows.error_handling.workflow_failure_state

- id: workflows.error_handling.retry_then_skip
  given:
    - a step is configured with `on_failure: :skip` and `max_retries: 2`
  when:
    - all retry attempts are exhausted
  then:
    - the step is marked as skipped
    - the workflow continues executing downstream steps
  covers:
    - workflows.error_handling.step_error_triggers_retry
    - workflows.error_handling.step_skip

- id: workflows.error_handling.worker_crash_recovery
  given:
    - a Worker process crashes mid-execution
  when:
    - the DynamicSupervisor restarts the Worker
  then:
    - `Store.load/2` restores the latest durable checkpoint
    - `pending_runnables/1` identifies in-flight work for re-dispatch
    - execution resumes from the checkpoint boundary
  covers:
    - workflows.error_handling.failure_mitigation_table
    - workflows.error_handling.idempotency_at_boundary

- id: workflows.error_handling.node_failure_lease_expiry
  given:
    - a node fails completely and stops renewing leases
  when:
    - the lease TTL expires
  then:
    - another node claims the orphaned executions with higher fence tokens
    - workflows resume from their latest durable state on the new node
  covers:
    - workflows.error_handling.failure_mitigation_table
    - workflows.error_handling.idempotency_at_boundary

- id: workflows.error_handling.stale_owner_after_split_brain
  given:
    - a network partition creates two nodes both believing they own an execution
  when:
    - the stale owner attempts a checkpoint write
  then:
    - fence token validation at the SQLite commit boundary rejects the write
    - the stale owner yields and the authoritative owner's state is preserved
  covers:
    - workflows.error_handling.failure_mitigation_table
```

## Verification

```spec-verification
- kind: doc_file
  target: docs/plans/durable-workflow-system-design.md
  covers:
    - workflows.error_handling.step_error_triggers_retry
    - workflows.error_handling.step_skip
    - workflows.error_handling.workflow_failure_state
    - workflows.error_handling.failure_mitigation_table
    - workflows.error_handling.idempotency_at_boundary
    - workflows.error_handling.retry_then_fail
    - workflows.error_handling.retry_then_skip
    - workflows.error_handling.worker_crash_recovery
    - workflows.error_handling.node_failure_lease_expiry
    - workflows.error_handling.stale_owner_after_split_brain

- kind: doc_file
  target: docs/plans/runic-research.md
  covers:
    - workflows.error_handling.step_error_triggers_retry
    - workflows.error_handling.idempotency_at_boundary
    - workflows.error_handling.worker_crash_recovery
```

## Exceptions

```spec-exceptions
- id: workflows.error_handling.impl_pending
  note: The repository does not yet contain error handling policy enforcement, skip markers, or failure-state transitions that would verify these contracts in code.
  relates_to:
    - workflows.error_handling.step_error_triggers_retry
    - workflows.error_handling.step_skip
    - workflows.error_handling.workflow_failure_state

- id: workflows.error_handling.compensation_deferred
  note: Automatic compensation and saga patterns are explicitly out of scope for v1. Workflows needing undo logic must author it as forward steps.
  relates_to:
    - workflows.error_handling.no_compensation_v1
```
