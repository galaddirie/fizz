# Workflow Signal Delivery

This spec covers external signal ingestion, deduplication scope, and delivery
semantics for active and dormant workflow runs.

```spec-meta
id: workflows.signal_delivery
kind: service
status: active
summary: Signals enter through a durable inbox, deduplicate per run and signal id, and use wakeup infrastructure to reach active or dormant workflow executions.
surface:
  - docs/plans/durable-workflow-system-design.md
  - .spec/decisions/signal-dedup-scope.md
```

## Requirements

```spec-requirements
- id: workflows.signal_delivery.inbox
  statement: External signals are durably accepted into a signal inbox even when the target workflow execution is dormant.
  priority: must
  stability: stable

- id: workflows.signal_delivery.dedup_scope
  statement: The signal idempotency key is scoped to `(run_id, signal_id)` rather than being globally unique across all workflow runs.
  priority: must
  stability: stable

- id: workflows.signal_delivery.idempotency
  statement: Repeated submissions with the same `(run_id, signal_id)` represent the same logical signal and must collapse to one durable inbox record and one logical delivery attempt.
  priority: must
  stability: stable

- id: workflows.signal_delivery.payload_distinctness
  statement: Identical signal names or payloads with different `signal_id` values remain distinct logical signals and must not be deduplicated by workflow fact equality alone.
  priority: must
  stability: stable

- id: workflows.signal_delivery.delivery_authority
  statement: Inbox uniqueness and delivery state are the authoritative dedup contract; workflow graph state may help recovery or inspection but does not replace the inbox idempotency key.
  priority: must
  stability: stable

- id: workflows.signal_delivery.wake_path
  statement: LISTEN/NOTIFY is a latency optimization, while inbox polling remains the authoritative catch-up path for missed notifications and dormant-run wakeups.
  priority: should
  stability: stable
```

## Scenarios

```spec-scenarios
- id: workflows.signal_delivery.duplicate_submission_same_run
  given:
    - a caller retries the same signal submission for the same workflow run
    - the retries reuse the same `signal_id`
  when:
    - the platform records the signal
  then:
    - only one logical signal is represented for that run and signal id
  covers:
    - workflows.signal_delivery.dedup_scope
    - workflows.signal_delivery.idempotency

- id: workflows.signal_delivery.same_signal_id_different_runs
  given:
    - two different workflow runs receive signals
    - both callers use the same `signal_id`
  when:
    - the signals are recorded
  then:
    - both signals are accepted because dedup scope is per run
  covers:
    - workflows.signal_delivery.dedup_scope

- id: workflows.signal_delivery.same_payload_distinct_ids
  given:
    - a workflow run receives two signals with identical names and payloads
    - the signals use different `signal_id` values
  when:
    - the signals are recorded and delivered
  then:
    - both signals remain distinct deliveries
  covers:
    - workflows.signal_delivery.payload_distinctness
    - workflows.signal_delivery.delivery_authority
```

## Verification

```spec-verification
- kind: doc_file
  target: docs/plans/durable-workflow-system-design.md
  covers:
    - workflows.signal_delivery.inbox
    - workflows.signal_delivery.wake_path

- kind: doc_file
  target: .spec/decisions/signal-dedup-scope.md
  covers:
    - workflows.signal_delivery.dedup_scope
    - workflows.signal_delivery.idempotency
    - workflows.signal_delivery.payload_distinctness
    - workflows.signal_delivery.delivery_authority
    - workflows.signal_delivery.duplicate_submission_same_run
    - workflows.signal_delivery.same_signal_id_different_runs
    - workflows.signal_delivery.same_payload_distinct_ids
```

## Exceptions

```spec-exceptions
- id: workflows.signal_delivery.impl_pending
  note: The repository does not yet contain a workflow signal inbox schema, router, or wakeup path implementation that would verify these signal-delivery contracts in source or tests.
  relates_to:
    - workflows.signal_delivery.inbox
    - workflows.signal_delivery.idempotency
```
