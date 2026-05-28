# Workflow Ownership

This spec covers the lease-based ownership model and fencing protocol that
enforce single-writer safety for workflow executions across a multi-node cluster.

```spec-meta
id: workflows.ownership
kind: runtime
status: active
summary: Workflow executions use lease-based ownership with monotonic fencing tokens to enforce single-writer safety at the storage boundary, preventing split-brain data corruption.
surface:
  - docs/plans/durable-workflow-system-design.md
  - docs/spec/decisions/single-writer-leasing-and-fencing.md
  - docs/spec/decisions/postgres-control-plane.md
```

## Requirements

```spec-requirements
- id: workflows.ownership.lease_acquisition
  statement: Ownership of a workflow execution is acquired by claiming a Postgres lease row with a bounded expiry window and atomically incrementing the monotonic fence token.
  priority: must
  stability: stable

- id: workflows.ownership.lease_renewal
  statement: The lease holder renews its leases on a cadence well within the TTL to prevent expiry during normal operation.
  priority: must
  stability: stable

- id: workflows.ownership.lease_expiry_failover
  statement: When a lease expires without renewal, any node may claim the orphaned execution by acquiring a new lease with a higher fence token, enabling recovery from node crashes.
  priority: must
  stability: stable

- id: workflows.ownership.fence_token_monotonic
  statement: The fence token is a monotonically increasing integer that increments on every lease acquisition, serving as the stale-write prevention mechanism independent of lease state.
  priority: must
  stability: stable

- id: workflows.ownership.fence_validation_at_commit
  statement: Fence token validation occurs at every SQLite mutation boundary via a two-phase protocol — (1) within a Postgres transaction, the owner conditionally updates a checkpoint-sequence column on the lease row only if its fence token still matches the authoritative value and the lease remains unexpired, and (2) the SQLite write proceeds only if the Postgres conditional update succeeded. This ensures stale-owner and expired-owner checks are linearized through Postgres, not relying on a bare read that could be stale by the time SQLite commits.
  priority: must
  stability: stable

- id: workflows.ownership.stale_owner_rejection
  statement: A checkpoint write attempt carrying a fence token lower than the current authoritative token must fail with a fencing error, preventing stale owners from corrupting workflow state after lease loss.
  priority: must
  stability: stable

- id: workflows.ownership.sqlite_mutations_fenced
  statement: Every mutating operation against a per-run SQLite store, including full checkpoint writes, explicit checkpoint writes, fact-row writes, metadata writes, and terminal final checkpoint writes, must pass through the same fenced authorization path before modifying the file.
  priority: must
  stability: stable

- id: workflows.ownership.lease_expiry_at_commit
  statement: A holder with a matching fence token but an expired lease must be rejected at authorization time before any SQLite mutation or active-run terminal mutation is committed.
  priority: must
  stability: stable

- id: workflows.ownership.lease_run_referential_integrity
  statement: Every workflow run lease row must reference an existing workflow run, and deleting a workflow run must delete its lease row so orphaned ownership records cannot survive run removal.
  priority: must
  stability: stable

- id: workflows.ownership.terminal_update_requires_owner
  statement: Runtime-owned terminal transitions for active runs, including completion, failure, abnormal worker termination, and cancellation cleanup, must be authorized by the current owner or by a separate explicit operator path that cannot be confused with stale worker ownership.
  priority: must
  stability: draft
```

## Scenarios

```spec-scenarios
- id: workflows.ownership.normal_lease_lifecycle
  given:
    - a node has acquired a lease for a workflow execution
  when:
    - the node renews the lease within the TTL
  then:
    - the lease remains valid with the same fence token
    - checkpoint writes continue to succeed
  covers:
    - workflows.ownership.lease_acquisition
    - workflows.ownership.lease_renewal

- id: workflows.ownership.node_crash_failover
  given:
    - a node crashes and stops renewing its leases
  when:
    - the lease TTL expires and another node claims the execution
  then:
    - the new owner acquires a lease with a higher fence token
    - the execution resumes from the latest durable checkpoint on the new node
  covers:
    - workflows.ownership.lease_expiry_failover
    - workflows.ownership.fence_token_monotonic

- id: workflows.ownership.stale_writer_fenced
  given:
    - a process pauses (GC, page fault, network delay) long enough for its lease to expire
    - another node acquires ownership with a higher fence token
  when:
    - the stale process resumes and attempts a checkpoint write
  then:
    - the fence token validation at the SQLite commit boundary rejects the write
    - the stale owner receives a fencing error and must yield
  covers:
    - workflows.ownership.fence_validation_at_commit
    - workflows.ownership.stale_owner_rejection

- id: workflows.ownership.stale_fact_write_fenced
  given:
    - a worker opened a per-run SQLite store with fence token 1
    - another node later acquired the same run with fence token 2
  when:
    - the stale worker attempts to persist an individual fact row
  then:
    - fenced authorization rejects the fact write before SQLite mutation
    - the existing fact table contents remain unchanged
  covers:
    - workflows.ownership.sqlite_mutations_fenced
    - workflows.ownership.stale_owner_rejection

- id: workflows.ownership.expired_owner_write_rejected
  given:
    - a worker still has a matching fence token for a run
    - the lease expiry time has passed without renewal
  when:
    - the worker attempts to write a checkpoint or fact row
  then:
    - authorization fails because the lease is expired
    - no SQLite state is modified
  covers:
    - workflows.ownership.fence_validation_at_commit
    - workflows.ownership.lease_expiry_at_commit

- id: workflows.ownership.stale_terminal_update_rejected
  given:
    - a stale worker loses ownership of an active run
    - a new owner has acquired a higher fence token
  when:
    - the stale worker attempts to mark the run completed or failed
  then:
    - the stale terminal mutation is rejected or routed through an explicit non-worker operator path
    - the new owner remains authoritative for runtime finalization
  covers:
    - workflows.ownership.terminal_update_requires_owner

- id: workflows.ownership.concurrent_claim_contention
  given:
    - a lease has expired for a workflow execution
    - two nodes attempt to claim it simultaneously
  when:
    - both nodes issue the lease acquisition UPDATE
  then:
    - exactly one succeeds due to Postgres row-level locking
    - the losing node retries or routes the execution elsewhere
  covers:
    - workflows.ownership.lease_acquisition
    - workflows.ownership.fence_token_monotonic

- id: workflows.ownership.lease_row_requires_run
  given:
    - no workflow run exists for a candidate run id
  when:
    - code attempts to create a lease row for that run id
  then:
    - the database rejects the lease row
    - deleting an existing workflow run also deletes its lease row
  covers:
    - workflows.ownership.lease_run_referential_integrity
```

## Verification

```spec-verification
- kind: doc_file
  target: docs/plans/durable-workflow-system-design.md
  covers:
    - workflows.ownership.lease_acquisition
    - workflows.ownership.lease_renewal
    - workflows.ownership.lease_expiry_failover
    - workflows.ownership.fence_token_monotonic
    - workflows.ownership.fence_validation_at_commit
    - workflows.ownership.stale_owner_rejection
    - workflows.ownership.normal_lease_lifecycle
    - workflows.ownership.node_crash_failover
    - workflows.ownership.stale_writer_fenced
    - workflows.ownership.concurrent_claim_contention

- kind: doc_file
  target: spec/decisions/single-writer-leasing-and-fencing.md
  covers:
    - workflows.ownership.lease_acquisition
    - workflows.ownership.fence_token_monotonic
    - workflows.ownership.fence_validation_at_commit
    - workflows.ownership.stale_owner_rejection
    - workflows.ownership.stale_writer_fenced

- kind: doc_file
  target: spec/decisions/postgres-control-plane.md
  covers:
    - workflows.ownership.lease_acquisition
    - workflows.ownership.lease_expiry_failover
    - workflows.ownership.fence_validation_at_commit

- kind: source_file
  target: lib/fizz/workflows/lease_manager.ex
  covers:
    - workflows.ownership.lease_acquisition
    - workflows.ownership.lease_renewal
    - workflows.ownership.lease_expiry_failover
    - workflows.ownership.fence_token_monotonic

- kind: source_file
  target: priv/repo/migrations/20260528220046_add_workflow_run_lease_foreign_key.exs
  covers:
    - workflows.ownership.lease_run_referential_integrity

- kind: source_file
  target: lib/fizz/workflows/store/sqlite_store.ex
  covers:
    - workflows.ownership.fence_validation_at_commit
    - workflows.ownership.sqlite_mutations_fenced

- kind: test_file
  target: test/fizz/workflows/lease_manager_test.exs
  covers:
    - workflows.ownership.normal_lease_lifecycle
    - workflows.ownership.node_crash_failover
    - workflows.ownership.concurrent_claim_contention

- kind: test_file
  target: test/fizz/workflows/store/sqlite_store_test.exs
  covers:
    - workflows.ownership.stale_writer_fenced
    - workflows.ownership.stale_fact_write_fenced
    - workflows.ownership.expired_owner_write_rejected

- kind: test_file
  target: test/fizz/workflows/workflow_run_lease_constraint_test.exs
  covers:
    - workflows.ownership.lease_row_requires_run
```

## Exceptions

```spec-exceptions
- id: workflows.ownership.terminal_fence_gap
  note: Runtime terminal transitions are implemented, but completion, failure, and cancellation status writes are not yet expressed through one owner-authorized finalization path with stale-owner tests.
  relates_to:
    - workflows.ownership.terminal_update_requires_owner
```
