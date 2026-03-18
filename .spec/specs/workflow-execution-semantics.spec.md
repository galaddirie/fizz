# Workflow Execution Semantics

This spec captures the durable execution guarantees and recovery rules for the
planned workflow runtime.

```spec-meta
id: workflows.execution_semantics
kind: runtime
status: active
summary: Workflow state progression is durable and replayable, while external side effects remain idempotency-boundary work owned by the surrounding platform.
surface:
  - docs/plans/runic-research.md
  - docs/plans/durable-workflow-system-design.md
  - .spec/decisions/runic-as-execution-kernel.md
  - .spec/decisions/per-execution-sqlite-store.md
  - .spec/decisions/single-writer-leasing-and-fencing.md
  - .spec/decisions/postgres-control-plane.md
  - .spec/decisions/durable-timer-model.md
```

## Requirements

```spec-requirements
- id: workflows.execution_semantics.kernel_boundary
  statement: Runic is the workflow execution kernel, while the platform remains responsible for cluster ownership, fencing, durable timers and signals, storage management, and operator semantics.
  priority: must
  stability: stable

- id: workflows.execution_semantics.progression_exactly_once
  statement: Workflow state progression is exactly-once relative to the persisted workflow history and checkpoint boundary.
  priority: must
  stability: stable

- id: workflows.execution_semantics.activities_at_least_once
  statement: External activity execution is at-least-once and must rely on idempotency contracts at service boundaries rather than assuming exactly-once remote effects.
  priority: must
  stability: stable

- id: workflows.execution_semantics.runnable_identity
  statement: Stable runnable identity is the durability-safe idempotency primitive for tracking and deduplicating external side effects.
  priority: must
  stability: stable

- id: workflows.execution_semantics.persist_after_apply
  statement: The durable unit is the workflow history, so persistence must happen after apply or at an intentionally chosen checkpoint boundary rather than only in external queue state.
  priority: must
  stability: stable

- id: workflows.execution_semantics.single_writer
  statement: Apply and durable commit are single-writer per workflow execution even when other runtime stages execute with parallelism.
  priority: must
  stability: stable

- id: workflows.execution_semantics.recovery
  statement: Recovery restores the latest durable workflow state and re-dispatches pending durable work based on persisted runnable lifecycle state.
  priority: must
  stability: stable

- id: workflows.execution_semantics.run_context_rebuild
  statement: `run_context` is ephemeral runtime state that must be reconstructed from durable metadata on resume rather than deserialized from checkpoints.
  priority: must
  stability: stable
```

## Scenarios

```spec-scenarios
- id: workflows.execution_semantics.crash_before_completion_commit
  given:
    - a durable runnable has been dispatched
    - the worker crashes before its completion is durably recorded
  when:
    - the workflow is restored
  then:
    - the restored workflow state identifies the runnable as pending
    - the platform may re-dispatch the work
  covers:
    - workflows.execution_semantics.activities_at_least_once
    - workflows.execution_semantics.recovery

- id: workflows.execution_semantics.remote_idempotency
  given:
    - an activity interacts with an external service
  when:
    - recovery causes the activity to be attempted again
  then:
    - the stable runnable identity is the input to the external idempotency contract
  covers:
    - workflows.execution_semantics.activities_at_least_once
    - workflows.execution_semantics.runnable_identity

- id: workflows.execution_semantics.resume_rebuilds_context
  given:
    - a workflow was checkpointed and later resumed
  when:
    - execution resumes on a new worker
  then:
    - durable workflow state is restored from persisted history
    - platform values are rebuilt into `run_context` before execution continues
  covers:
    - workflows.execution_semantics.recovery
    - workflows.execution_semantics.run_context_rebuild

- id: workflows.execution_semantics.parallel_fan_out_fan_in
  given:
    - a workflow DAG has a fan-out node producing multiple independent branches that converge at a join node
  when:
    - all branch inputs are satisfied and dispatched concurrently
  then:
    - each branch executes independently
    - results apply in completion order through the single-writer apply boundary
    - the join node fires once all required branch outputs are available
  covers:
    - workflows.execution_semantics.progression_exactly_once
    - workflows.execution_semantics.single_writer

- id: workflows.execution_semantics.partial_failure_in_parallel
  given:
    - a workflow has multiple parallel branches executing concurrently
    - one branch's activity fails with `on_failure: :fail` and exhausts retries
  when:
    - the failed branch is marked terminal
  then:
    - remaining in-flight branches complete or are cancelled according to policy
    - the workflow transitions to a failed state
  covers:
    - workflows.execution_semantics.recovery
    - workflows.execution_semantics.activities_at_least_once
```

## Verification

```spec-verification
- kind: doc_file
  target: docs/plans/runic-research.md
  covers:
    - workflows.execution_semantics.kernel_boundary
    - workflows.execution_semantics.activities_at_least_once
    - workflows.execution_semantics.runnable_identity
    - workflows.execution_semantics.persist_after_apply
    - workflows.execution_semantics.single_writer
    - workflows.execution_semantics.recovery
    - workflows.execution_semantics.run_context_rebuild
    - workflows.execution_semantics.crash_before_completion_commit
    - workflows.execution_semantics.remote_idempotency
    - workflows.execution_semantics.resume_rebuilds_context

- kind: doc_file
  target: docs/plans/durable-workflow-system-design.md
  covers:
    - workflows.execution_semantics.kernel_boundary
    - workflows.execution_semantics.progression_exactly_once
    - workflows.execution_semantics.activities_at_least_once
    - workflows.execution_semantics.runnable_identity
    - workflows.execution_semantics.persist_after_apply
    - workflows.execution_semantics.single_writer
    - workflows.execution_semantics.recovery
```

## Exceptions

```spec-exceptions
- id: workflows.execution_semantics.control_plane_out_of_scope
  note: Passivation tiers, observability, and rollout sequencing remain outside this spec. The durable timer model decision establishes the platform/kernel timer boundary, and the Postgres control plane decision establishes the coordination layer; their schemas and firing mechanics are tracked separately from the core execution kernel contract.
  relates_to:
    - workflows.execution_semantics.kernel_boundary

- id: workflows.execution_semantics.impl_pending
  note: The repository does not yet contain the `Fizz.Workflows.Runner`, store, lease, or resume-path implementation that would verify these runtime guarantees in source or tests.
  relates_to:
    - workflows.execution_semantics.progression_exactly_once
    - workflows.execution_semantics.recovery
    - workflows.execution_semantics.run_context_rebuild
```
