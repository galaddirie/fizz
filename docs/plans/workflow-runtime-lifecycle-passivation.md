# Workflow Runtime Lifecycle and Passivation Safety Plan

Status date: 2026-05-28

## Goal

Make terminal transitions and passivation safe under active work, sleeping runs, worker crashes, and lease handoff.

## Non-Goals

- Do not add a new state machine library.
- Do not change public run statuses unless required by correctness.
- Do not redesign Litestream or S3 storage.
- Do not combine broad module extraction with lifecycle behavior changes.

## Spec Updates

Update:

- `docs/spec/specs/workflow-run-lifecycle.spec.md`
- `docs/spec/specs/workflow-storage.spec.md`
- `docs/spec/specs/workflow-ownership.spec.md`

Key scenarios:

- `workflows.run_lifecycle.active_work_not_passivated`
- `workflows.run_lifecycle.sleeping_checkpoint_can_passivate`
- `workflows.run_lifecycle.wal_checkpoint_failure_preserves_files`
- `workflows.run_lifecycle.terminal_cleanup_is_consistent`
- `workflows.storage.wal_checkpoint_failure_preserves_local_files`

## Plan

### Phase 1 - Characterization

Add tests that lock current and target behavior:

- active worker with old `last_active_at` is not passivated
- sleeping run with valid checkpoint can passivate without a live worker
- run without worker and without checkpoint is skipped
- WAL checkpoint failure preserves local files
- completion, failure, cancellation, and abnormal worker termination all cancel pending timers and stop lease renewal

Exit criteria: unsafe passivation and cleanup paths are visible in focused tests.

### Phase 2 - Worker Idleness API

Add a worker API such as `Worker.idle?/1` or `Worker.passivate/2`.

The API must account for:

- active runnable tasks
- queued runnable requests
- retrying runnables
- local timer settlement
- workflow state that can immediately dispatch more work

Prefer `Worker.passivate/2` if the worker must atomically check idleness, persist, and stop. A separate `idle?/1` can race if the worker receives work between check and stop.

Exit criteria: passivation can ask the live owner whether it is actually idle.

### Phase 3 - Candidate Handling

Change `PassivationSweeper` so `last_active_at` is only a query filter.

For registered workers:

- call the worker passivation API
- skip if active or queued work exists
- only stop after final checkpoint succeeds

For no-worker runs:

- allow passivation only for `:sleeping` or otherwise passivation-eligible states
- require a valid checkpoint
- require no active lease owner that could still be executing work

Exit criteria: an old timestamp alone cannot stop active execution.

### Phase 4 - Cold Eviction Safety

Change cold eviction so local files are deleted only after WAL checkpoint succeeds or an equivalent replication proof exists.

On checkpoint failure:

- preserve `.sqlite`, `-wal`, and `-shm`
- log enough context for operator diagnosis
- skip the passivation or mark it as non-cold-evicted according to the final implementation decision

Exit criteria: failed checkpointing cannot destroy the best local recovery source.

### Phase 5 - Terminal Finalization

Introduce one internal finalization path for terminal transitions.

It should own:

- final checkpoint when possible
- terminal status update
- pending timer cancellation
- signal settlement when applicable
- terminal broadcast
- lease release or renewal stop

Exit criteria: completion, failure, cancellation, and abnormal termination share the same cleanup contract.

## Acceptance Criteria

- Long-running active work is not passivated solely because `last_active_at` is old.
- Sleeping runs with valid checkpoints can passivate.
- WAL checkpoint failure preserves local files.
- All terminal paths cancel pending timers.
- Lease release or renewal stop is consistent across terminal paths.
- Broadcast payload shape remains compatible with existing LiveView consumers.

## Test Commands

```bash
mix test test/fizz/workflows/passivation_sweeper_test.exs
mix test test/fizz/workflows/runner/worker_test.exs
mix test test/fizz/workflows/runner/worker_failure_test.exs
mix test test/fizz/workflows/timer_poller_test.exs
mix precommit
```

## Rollout / Rollback

Roll out after ownership and storage safety. Rollback is code revert unless migrations are included. If finalization changes events, keep payload shape stable or update LiveView tests in the same PR.

## Dependencies

- Fenced store writes.
- Worker visibility into active and queued execution state.
- Existing `WorkflowRun.transition_status/2` validation.

