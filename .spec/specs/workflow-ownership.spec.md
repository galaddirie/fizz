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
  - .spec/decisions/single-writer-leasing-and-fencing.md
  - .spec/decisions/postgres-control-plane.md
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
  statement: Fence token validation occurs at the SQLite commit boundary via a two-phase protocol — (1) within a Postgres transaction, the owner conditionally updates a checkpoint-sequence column on the lease row only if its fence token still matches the authoritative value, and (2) the SQLite write proceeds only if the Postgres conditional update succeeded. This ensures the stale-owner check and the commit authorization are linearized through Postgres, not relying on a bare read that could be stale by the time SQLite commits.
  priority: must
  stability: stable

- id: workflows.ownership.stale_owner_rejection
  statement: A checkpoint write attempt carrying a fence token lower than the current authoritative token must fail with a fencing error, preventing stale owners from corrupting workflow state after lease loss.
  priority: must
  stability: stable
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
  target: .spec/decisions/single-writer-leasing-and-fencing.md
  covers:
    - workflows.ownership.lease_acquisition
    - workflows.ownership.fence_token_monotonic
    - workflows.ownership.fence_validation_at_commit
    - workflows.ownership.stale_owner_rejection
    - workflows.ownership.stale_writer_fenced

- kind: doc_file
  target: .spec/decisions/postgres-control-plane.md
  covers:
    - workflows.ownership.lease_acquisition
    - workflows.ownership.lease_expiry_failover
    - workflows.ownership.fence_validation_at_commit
```

## Exceptions

```spec-exceptions
- id: workflows.ownership.impl_pending
  note: The repository does not yet contain the LeaseManager, fence validation in the Store adapter, or failover orchestration that would enforce these ownership contracts in code.
  relates_to:
    - workflows.ownership.lease_acquisition
    - workflows.ownership.lease_renewal
    - workflows.ownership.fence_validation_at_commit
    - workflows.ownership.stale_owner_rejection
```
