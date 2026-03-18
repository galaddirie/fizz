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
  - .spec/decisions/per-execution-sqlite-store.md
  - .spec/decisions/postgres-control-plane.md
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
  statement: The PassivationSweeper periodically scans active workflows and transitions idle executions through passivation tiers based on a configurable idle threshold.
  priority: must
  stability: stable

- id: workflows.run_lifecycle.last_active_tracking
  statement: A `last_active_at` timestamp is updated on meaningful execution activity such as step completion or signal delivery and drives passivation eligibility decisions.
  priority: must
  stability: stable

- id: workflows.run_lifecycle.wake_on_event
  statement: Dormant executions in PASSIVATED or SLEEPING status must be woken when a durable timer fires or an external signal is delivered, transitioning back to RUNNING via lease acquisition and state restoration.
  priority: must
  stability: stable
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
    - the run transitions to PASSIVATED
    - the Worker is stopped and storage tiers advance per the storage contract
  covers:
    - workflows.run_lifecycle.passivation_sweep
    - workflows.run_lifecycle.last_active_tracking
    - workflows.run_lifecycle.valid_transitions

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
    - a PASSIVATED run with SQLite in S3
  when:
    - a timer fires or an external signal arrives
  then:
    - lease is acquired from the control plane
    - SQLite is downloaded and the workflow is restored
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
  target: .spec/decisions/per-execution-sqlite-store.md
  covers:
    - workflows.run_lifecycle.passivation_sweep

- kind: doc_file
  target: .spec/decisions/postgres-control-plane.md
  covers:
    - workflows.run_lifecycle.postgres_statuses
    - workflows.run_lifecycle.wake_on_event
```

## Exceptions

```spec-exceptions
- id: workflows.run_lifecycle.impl_pending
  note: The repository does not yet contain the WorkflowRun schema, status transition enforcement, PassivationSweeper, or wake-from-cold orchestration that would enforce these lifecycle contracts in code.
  relates_to:
    - workflows.run_lifecycle.postgres_statuses
    - workflows.run_lifecycle.valid_transitions
    - workflows.run_lifecycle.passivation_sweep
    - workflows.run_lifecycle.wake_on_event
```
