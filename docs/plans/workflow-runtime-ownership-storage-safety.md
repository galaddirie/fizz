# Workflow Runtime Ownership and Storage Safety Plan

Status date: 2026-05-28

## Goal

Make every mutating per-run SQLite operation require the current unexpired Postgres lease and fence token. This includes full checkpoint writes, explicit checkpoint writes, fact-row writes, metadata writes that happen during mutation, and final checkpoint writes during terminalization.

## Non-Goals

- Do not split the public `Fizz.Workflows` context.
- Do not replace the per-run SQLite storage model.
- Do not change Runic checkpoint format.
- Do not add hybrid or lazy rehydration in this phase.

## Spec Updates

Update:

- `docs/spec/specs/workflow-ownership.spec.md`
- `docs/spec/specs/workflow-storage.spec.md`

The specs should describe the target contract and retain explicit exceptions until implementation lands:

- `workflows.ownership.sqlite_mutations_fenced`
- `workflows.ownership.lease_expiry_at_commit`
- `workflows.ownership.stale_fact_write_fenced`
- `workflows.ownership.expired_owner_write_rejected`
- `workflows.storage.fenced_fact_writes`
- `workflows.storage.fact_hash_immutability`
- `workflows.storage.fenced_standalone_fact_write`

## Plan

### Phase 1 - Characterization

Add focused tests in `test/fizz/workflows/store/sqlite_store_test.exs`:

- stale fence rejects `save_fact/3`
- expired lease rejects `save/3`
- expired lease rejects `save_fact/3`
- current owner still saves checkpoints and facts
- duplicate fact hash does not overwrite existing content unless content identity is explicitly proven

Exit criteria: tests expose current gaps without requiring module extraction.

### Phase 2 - Fenced Write Helper

Create one internal helper in `Fizz.Workflows.Store.SqliteStore`, for example:

```elixir
with_fenced_write(run_id, state, fun)
```

It should:

- ensure the store is initialized
- authorize the write by conditionally updating `workflow_run_leases.checkpoint_seq`
- require `run_id`, `fence_token`, and `lease_expiry > NOW()`
- run the SQLite mutation only after Postgres authorization succeeds
- raise or return the existing stale-owner error shape consistently

Exit criteria: `save/3`, `checkpoint/3`, and `save_fact/3` can share one authorization path.

### Phase 3 - Fact Conflict Semantics

Confirm whether Runic fact hashes are content-addressed and immutable.

If they are immutable:

- checkpoint fact persistence should keep `ON CONFLICT DO NOTHING`
- standalone fact persistence should either `DO NOTHING` for identical content or return a conflict error for different content
- `DO UPDATE` should be removed from standalone fact writes

If they are not immutable:

- document the actual overwrite rule in `workflow-storage.spec.md`
- keep overwrite behavior fenced by current ownership

Exit criteria: fact-row conflict behavior is explicit and tested.

### Phase 4 - Lease FK Migration

Add a migration only after checking existing data:

- remove or repair orphaned `workflow_run_leases` rows
- add a foreign key from `workflow_run_leases.run_id` to `workflow_runs.id`
- validate down migration drops only the added FK

Exit criteria: lease rows cannot outlive their run without an intentional migration path.

## Acceptance Criteria

- A stale owner cannot write a fact after another owner acquires the run.
- A holder with an expired lease cannot write checkpoints or facts.
- Current owners can still checkpoint and persist facts.
- Existing SQLite files remain readable.
- Fact hash conflict behavior is explicit.
- Spec exceptions are narrowed to remaining real gaps.

## Test Commands

```bash
mix test test/fizz/workflows/store/sqlite_store_test.exs
mix test test/fizz/workflows/lease_manager_test.exs
mix test test/fizz/workflows/workflow_run_test.exs
mix precommit
```

## Rollout / Rollback

Ship before passivation or delivery refactors. Code-only changes roll back by revert. The lease FK migration must include orphan cleanup and a tested rollback before it ships.

## Dependencies

- Existing `workflow_run_leases` ownership model.
- Current `Fizz.Workflows.Store.SqliteStore` adapter behavior.
- Decision on fact hash immutability.

