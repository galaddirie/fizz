# Workflow Run Lifecycle

This spec covers the run-level state machine, valid status transitions, terminal
states, per-state operation validity, and passivation sweep mechanics.

```spec-meta
id: workflows.run_lifecycle
kind: runtime
status: active
summary: Workflow runs progress through a defined status graph with terminal states, per-state operation guards, and periodic passivation sweeps that transition idle executions through storage tiers.
surface:
  - docs/plans/durable-workflow-system-design.md
  - docs/spec/decisions/per-execution-sqlite-store.md
  - docs/spec/decisions/postgres-control-plane.md
```

## Requirements

```spec-requirements
- id: workflows.run_lifecycle.postgres_statuses
  statement: A workflow run's Postgres status must be one of PENDING, RUNNING, SLEEPING, PASSIVATED, COMPLETED, FAILED, CANCELLED, or CONTINUED.
  priority: must
  stability: stable

- id: workflows.run_lifecycle.valid_transitions
  statement: Status transitions follow a defined graph — PENDING to RUNNING, RUNNING to SLEEPING or PASSIVATED or COMPLETED or FAILED or CANCELLED or CONTINUED, SLEEPING to RUNNING or PASSIVATED or CANCELLED, PASSIVATED to RUNNING — and invalid transitions must be rejected.
  priority: must
  stability: stable

- id: workflows.run_lifecycle.terminal_states
  statement: COMPLETED, FAILED, CANCELLED, and CONTINUED are terminal states from which no further execution or state mutation may occur.
  priority: must
  stability: stable

- id: workflows.run_lifecycle.operations_per_state
  statement: Each run status defines which operations are valid — signal acceptance into the durable inbox is unconditional regardless of run state, signal delivery to the workflow graph requires a non-terminal state, cancellation requires a non-terminal state, and passivation requires RUNNING or SLEEPING.
  priority: must
  stability: stable

- id: workflows.run_lifecycle.passivation_sweep
  statement: The PassivationSweeper periodically scans active workflows and transitions eligible idle executions through passivation tiers based on a configurable idle threshold. `last_active_at` is only a candidate filter; a live worker must confirm it has no active or queued work before being stopped for passivation.
  priority: must
  stability: stable

- id: workflows.run_lifecycle.last_active_tracking
  statement: A `last_active_at` timestamp is updated on meaningful execution activity such as step completion or signal delivery and drives passivation candidate selection. It is useful for filtering and observability, but it is not sufficient proof that a running worker is idle.
  priority: must
  stability: stable

- id: workflows.run_lifecycle.wake_on_event
  statement: Dormant executions in PASSIVATED or SLEEPING status must be woken when a durable timer fires or an external signal is delivered, transitioning back to RUNNING via lease acquisition and state restoration.
  priority: must
  stability: stable

- id: workflows.run_lifecycle.active_work_guard
  statement: A RUNNING workflow with active tasks, queued runnables, local timers being settled, or retry work pending must not be passivated solely because its `last_active_at` timestamp is old.
  priority: must
  stability: stable

- id: workflows.run_lifecycle.db_only_passivation_guard
  statement: If no worker process is registered for a run, DB-only passivation is allowed only when the run is already SLEEPING or otherwise passivation-eligible, has a valid checkpoint, and has no active lease owner that could still be executing work.
  priority: must
  stability: stable

- id: workflows.run_lifecycle.cold_evict_requires_wal_checkpoint
  statement: Local SQLite files may be deleted during cold eviction only after the WAL checkpoint succeeds or after the runtime can otherwise prove the local file is safely replicated; a WAL checkpoint failure must preserve local files.
  priority: must
  stability: stable

- id: workflows.run_lifecycle.terminal_finalization
  statement: Completion, failure, cancellation, and abnormal worker termination must converge on one finalization contract: persist the final checkpoint when possible, update terminal status, cancel pending timers, broadcast the terminal state, and release or stop renewing the lease.
  priority: must
  stability: draft
```

## Scenarios

```spec-scenarios
- id: workflows.run_lifecycle.start_to_completion
  given:
    - a new workflow run is created in PENDING status
  when:
    - execution begins and all steps complete successfully
  then:
    - the status transitions PENDING to RUNNING to COMPLETED
    - no further execution occurs after reaching COMPLETED
  covers:
    - workflows.run_lifecycle.postgres_statuses
    - workflows.run_lifecycle.valid_transitions
    - workflows.run_lifecycle.terminal_states

- id: workflows.run_lifecycle.idle_passivation
  given:
    - a RUNNING workflow has been idle beyond the configured threshold
  when:
    - the PassivationSweeper scans active workflows
  then:
    - the Worker is stopped with a final checkpoint
    - the local SQLite file is WAL-checkpointed and evicted (cold tier)
    - the run transitions to PASSIVATED
    - the lease is released
  covers:
    - workflows.run_lifecycle.passivation_sweep
    - workflows.run_lifecycle.last_active_tracking
    - workflows.run_lifecycle.valid_transitions

- id: workflows.run_lifecycle.active_work_not_passivated
  given:
    - a RUNNING workflow has an old `last_active_at` timestamp
    - its live worker still has an active task or queued runnable
  when:
    - the PassivationSweeper evaluates the run
  then:
    - the worker is not stopped
    - the run remains RUNNING
    - no local SQLite files are evicted
  covers:
    - workflows.run_lifecycle.passivation_sweep
    - workflows.run_lifecycle.active_work_guard

- id: workflows.run_lifecycle.sleeping_checkpoint_can_passivate
  given:
    - a SLEEPING workflow has no registered worker
    - a valid checkpoint exists in the per-run SQLite file
  when:
    - the PassivationSweeper evaluates the run
  then:
    - the run may transition to PASSIVATED without a live worker stop
    - the checkpoint remains the recovery source for later wakeup
  covers:
    - workflows.run_lifecycle.db_only_passivation_guard
    - workflows.run_lifecycle.passivation_sweep

- id: workflows.run_lifecycle.wal_checkpoint_failure_preserves_files
  given:
    - a passivation candidate has local SQLite files
    - cold eviction attempts a WAL checkpoint before deleting files
  when:
    - WAL checkpoint fails
  then:
    - the local SQLite, WAL, and SHM files are preserved
    - the run is not treated as safely cold-evicted
  covers:
    - workflows.run_lifecycle.cold_evict_requires_wal_checkpoint

- id: workflows.run_lifecycle.terminal_cleanup_is_consistent
  given:
    - a workflow run reaches a terminal state through completion, failure, cancellation, or abnormal worker termination
  when:
    - finalization completes
  then:
    - pending timers are cancelled
    - the terminal status is broadcast using the same payload shape
    - the run lease is released or no longer renewed
  covers:
    - workflows.run_lifecycle.terminal_states
    - workflows.run_lifecycle.terminal_finalization

- id: workflows.run_lifecycle.signal_to_terminal_rejected
  given:
    - a workflow run is in COMPLETED status
  when:
    - an external signal targets the run
  then:
    - the signal is accepted into the durable inbox
    - delivery to the workflow is skipped because the run is terminal
    - the run status does not change
  covers:
    - workflows.run_lifecycle.terminal_states
    - workflows.run_lifecycle.operations_per_state

- id: workflows.run_lifecycle.cancel_sleeping_run
  given:
    - a workflow run is in SLEEPING status waiting on a durable timer
  when:
    - cancellation is requested
  then:
    - pending timers for the run are cancelled
    - the run transitions to CANCELLED
    - future timer fires for this run are no-ops
  covers:
    - workflows.run_lifecycle.operations_per_state
    - workflows.run_lifecycle.valid_transitions
    - workflows.run_lifecycle.terminal_states

- id: workflows.run_lifecycle.wake_from_cold
  given:
    - a PASSIVATED run with local SQLite evicted and replica in S3
  when:
    - a timer fires or an external signal arrives
  then:
    - lease is acquired from the control plane
    - "`maybe_restore_from_s3` detects the missing local file and restores from S3 via `litestream restore`"
    - the workflow is reconstructed from the restored checkpoint
    - the run transitions to RUNNING and execution resumes
  covers:
    - workflows.run_lifecycle.wake_on_event
    - workflows.run_lifecycle.valid_transitions
```

## Verification

```spec-verification
- kind: doc_file
  target: docs/plans/durable-workflow-system-design.md
  covers:
    - workflows.run_lifecycle.postgres_statuses
    - workflows.run_lifecycle.valid_transitions
    - workflows.run_lifecycle.terminal_states
    - workflows.run_lifecycle.operations_per_state
    - workflows.run_lifecycle.passivation_sweep
    - workflows.run_lifecycle.last_active_tracking
    - workflows.run_lifecycle.wake_on_event
    - workflows.run_lifecycle.start_to_completion
    - workflows.run_lifecycle.idle_passivation
    - workflows.run_lifecycle.cancel_sleeping_run
    - workflows.run_lifecycle.wake_from_cold

- kind: doc_file
  target: spec/decisions/per-execution-sqlite-store.md
  covers:
    - workflows.run_lifecycle.passivation_sweep

- kind: doc_file
  target: spec/decisions/postgres-control-plane.md
  covers:
    - workflows.run_lifecycle.postgres_statuses
    - workflows.run_lifecycle.wake_on_event

- kind: source_file
  target: lib/fizz/workflows/passivation_sweeper.ex
  covers:
    - workflows.run_lifecycle.passivation_sweep
    - workflows.run_lifecycle.db_only_passivation_guard
    - workflows.run_lifecycle.cold_evict_requires_wal_checkpoint

- kind: source_file
  target: lib/fizz/workflows.ex
  covers:
    - workflows.run_lifecycle.terminal_finalization

- kind: source_file
  target: lib/fizz/workflows/runner/worker.ex
  covers:
    - workflows.run_lifecycle.active_work_guard
    - workflows.run_lifecycle.terminal_finalization

- kind: test_file
  target: test/fizz/workflows/passivation_sweeper_test.exs
  covers:
    - workflows.run_lifecycle.idle_passivation
    - workflows.run_lifecycle.active_work_not_passivated
    - workflows.run_lifecycle.sleeping_checkpoint_can_passivate
    - workflows.run_lifecycle.wal_checkpoint_failure_preserves_files

- kind: test_file
  target: test/fizz/workflows/runner/worker_failure_test.exs
  covers:
    - workflows.run_lifecycle.terminal_cleanup_is_consistent

- kind: test_file
  target: test/fizz/workflows_test.exs
  covers:
    - workflows.run_lifecycle.terminal_cleanup_is_consistent
```

## Exceptions

```spec-exceptions
```
