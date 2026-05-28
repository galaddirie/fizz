# Workflow Storage

This spec covers the per-execution storage model, checkpoint format, passivation
tiers, rehydration modes, and schema versioning for durable workflow state.

```spec-meta
id: workflows.storage
kind: component
status: active
summary: Each workflow execution persists its state in a dedicated SQLite file through configurable checkpoint strategies, with four-tier passivation for cost-efficient dormancy and multiple rehydration modes for recovery.
surface:
  - docs/plans/durable-workflow-system-design.md
  - docs/plans/runic-research.md
  - docs/spec/decisions/per-execution-sqlite-store.md
  - docs/spec/decisions/postgres-control-plane.md
```

## Requirements

```spec-requirements
- id: workflows.storage.one_to_one_sqlite
  statement: Each workflow execution owns exactly one SQLite database file with a 1:1 execution-to-database mapping, preserving replay boundaries and execution isolation.
  priority: must
  stability: stable

- id: workflows.storage.checkpoint_format
  statement: The canonical persisted checkpoint is the serialized output of `Workflow.log/1` via `:erlang.term_to_binary` with compression, containing the complete workflow history needed for reconstruction via `Workflow.from_log/1`.
  priority: must
  stability: stable

- id: workflows.storage.checkpoint_strategies
  statement: The store supports configurable checkpoint strategies per execution — `every_cycle` (after each react cycle), `every_n` (every N completed runnables), `on_complete` (only when workflow satisfies), and `manual` (explicit `Runner.checkpoint/2` calls only) — trading durability against write overhead. Strategies other than `every_cycle` accept weaker crash-recovery guarantees — progress since the last checkpoint is lost on crash, Litestream can only replicate what has been written to SQLite, and the sub-second RPO guarantee applies only to checkpointed state.
  priority: must
  stability: stable

- id: workflows.storage.passivation_tiers
  statement: Execution storage follows three tiers — HOT (Tier 0, Worker alive, SQLite open on local SSD), COLD (Tier 1, Worker stopped, local SQLite WAL-checkpointed and evicted, S3 replica authoritative via Litestream), and ARCHIVE (Tier 2, completed execution in S3 Glacier for operator inspection only). The PassivationSweeper transitions idle executions directly from HOT to COLD by stopping the worker, flushing the WAL, and deleting the local file. Wake-up restores the SQLite file from S3 via `litestream restore` before rehydration.
  priority: must
  stability: stable

- id: workflows.storage.passivation_preserves_uncheckpointed_files
  statement: Passivation may delete local SQLite, WAL, or SHM files only after the final checkpoint and WAL checkpoint have succeeded, or after an equivalent replication proof exists. If WAL checkpointing fails, local files must remain available for retry, local recovery, and operator inspection.
  priority: must
  stability: stable

- id: workflows.storage.fact_level_persistence
  statement: When hybrid or lazy rehydration is enabled for an execution, the store adapter must persist individual fact values keyed by content hash alongside the canonical full-log checkpoint — for example as a `facts(hash, value)` table in the per-execution SQLite file. The full-log checkpoint remains the canonical recovery path and integrity guarantee; the fact table is a supplementary index that enables `FactResolver.resolve/2` to load individual values without deserializing the entire log. Fact rows written as part of a checkpoint must be committed in the same SQLite transaction as the log blob; fact rows written through an explicit store call must share the same fenced write authorization as canonical checkpoint writes.
  priority: must
  stability: stable

- id: workflows.storage.fact_hash_immutability
  statement: A fact hash represents content identity. Once a fact row exists for a hash, later writes for the same hash must either confirm the same value or leave the existing row unchanged; stale owners must never be able to overwrite fact content by reusing a hash.
  priority: must
  stability: draft

- id: workflows.storage.fenced_fact_writes
  statement: Standalone fact persistence must require a current unexpired run lease and matching fence token before mutating the per-run SQLite `facts` table.
  priority: must
  stability: stable

- id: workflows.storage.rehydration_modes
  statement: Cold-load recovery supports three rehydration modes — full (reconstruct via `Workflow.from_log/1` with all fact values, highest memory, immediate readiness), hybrid (lean replay via `Workflow.from_events/3` with `fact_mode: :ref` producing `FactRef` vertices, then `Rehydration.resolve_hot/3` loads only hot facts from the fact table), and lazy (all facts as `FactRef`, resolved on demand by `FactResolver` during dispatch) — selectable per resume based on workflow size and memory constraints. Full rehydration requires only the canonical log checkpoint. Hybrid and lazy rehydration additionally require fact-level persistence as defined in `workflows.storage.fact_level_persistence`.
  priority: must
  stability: stable

- id: workflows.storage.litestream_replication
  statement: Active SQLite files are continuously replicated to S3 via Litestream WAL streaming, providing sub-second recovery point objective for disaster recovery independent of checkpoint strategy. The platform manages the Litestream binary as a supervised process using directory-based replication — a single Litestream process watches the workflow data directory tree, automatically discovering and replicating new SQLite files as executions are created. Cold-start restore uses `litestream restore` to download a database from S3 to a local path before the Worker opens it.
  priority: must
  stability: stable

- id: workflows.storage.litestream_directory_layout
  statement: The workflow data directory follows the structure `{data_dir}/{org_id}/{project_id}/{hash_prefix}/{run_id}.sqlite` and the Litestream config uses directory-mode replication with `recursive: true` and `watch: true` to track all databases under the root data directory. The S3 replica preserves the same directory structure as keys, enabling restore by run_id without a separate path registry.
  priority: must
  stability: stable

- id: workflows.storage.litestream_restore
  statement: Cold-start restore invokes `litestream restore -o {local_path} {replica_url}` to download a SQLite database from S3 before the Worker opens it. Restore only runs if the local file does not already exist. The platform must verify the restore succeeded and the file is a valid SQLite database before proceeding with rehydration.
  priority: must
  stability: stable

- id: workflows.storage.schema_versioning
  statement: SQLite schema version is tracked via `PRAGMA user_version`, migration-on-wake runs forward migrations within transactions when the file version is lower than the current code, and the runtime refuses to open databases with a higher version than it knows.
  priority: must
  stability: stable
```

## Scenarios

```spec-scenarios
- id: workflows.storage.checkpoint_and_restore
  given:
    - a running workflow has progressed through several steps and checkpointed to SQLite
  when:
    - the workflow is restored from the persisted checkpoint
  then:
    - "`Workflow.from_log/1` reconstructs the complete workflow state including structure, facts, causal history, and pending runnables"
    - the restored workflow can continue execution from the checkpoint boundary
  covers:
    - workflows.storage.one_to_one_sqlite
    - workflows.storage.checkpoint_format

- id: workflows.storage.passivation_to_cold
  given:
    - a HOT-tier execution has been idle beyond the configured passivation threshold
    - Litestream has been continuously replicating the file's WAL to S3 via directory-mode replication
  when:
    - the passivation sweeper runs
  then:
    - the Worker is stopped with a final checkpoint persisted to local SQLite
    - "the SQLite WAL is checkpointed via `PRAGMA wal_checkpoint(TRUNCATE)` to ensure all data is replicated"
    - the local SQLite file and WAL/SHM files are deleted (cold eviction)
    - the Postgres control plane is updated with PASSIVATED status and the lease is released
  covers:
    - workflows.storage.passivation_tiers
    - workflows.storage.passivation_preserves_uncheckpointed_files
    - workflows.storage.litestream_replication
    - workflows.storage.litestream_directory_layout

- id: workflows.storage.wal_checkpoint_failure_preserves_local_files
  given:
    - a run is selected for passivation
    - the local SQLite file has WAL or SHM state that must be checkpointed before cold eviction
  when:
    - WAL checkpointing fails
  then:
    - local SQLite, WAL, and SHM files are not deleted
    - the run remains recoverable from local storage
  covers:
    - workflows.storage.passivation_preserves_uncheckpointed_files

- id: workflows.storage.cold_restore_from_s3
  given:
    - a COLD (passivated) execution with SQLite in S3 receives a wake-up event (signal or timer)
    - the local SQLite file does not exist (evicted during passivation)
  when:
    - the platform initiates resume via `start_run_worker`
  then:
    - "`maybe_restore_from_s3` detects the missing local file and calls `LitestreamManager.restore/2`"
    - "`litestream restore -o {local_path} {replica_url}` downloads the database from S3"
    - the platform verifies the restored file is a valid SQLite database via integrity check
    - "`SqliteStore.init` opens the restored file and runs schema migration if needed"
    - the workflow is reconstructed from the checkpoint and execution resumes
    - Litestream directory-mode replication automatically picks up the restored file for ongoing replication
  covers:
    - workflows.storage.passivation_tiers
    - workflows.storage.rehydration_modes
    - workflows.storage.schema_versioning
    - workflows.storage.litestream_restore
    - workflows.storage.litestream_directory_layout

- id: workflows.storage.litestream_auto_discovery
  given:
    - the Litestream process is running with directory-mode replication watching the workflow data root
  when:
    - a new workflow execution creates a SQLite file in the directory tree
  then:
    - Litestream automatically discovers the new file and begins WAL replication to S3
    - the S3 key structure mirrors the local directory structure
    - no per-database configuration change or Litestream restart is required
  covers:
    - workflows.storage.litestream_replication
    - workflows.storage.litestream_directory_layout

- id: workflows.storage.schema_migration_on_wake
  given:
    - a SQLite file carries a `user_version` lower than the current code version
  when:
    - the file is opened for resume
  then:
    - forward migrations run in order within transactions
    - "`user_version` is incremented to the current version"
    - the workflow resumes normally on the upgraded schema
  covers:
    - workflows.storage.schema_versioning

- id: workflows.storage.fenced_standalone_fact_write
  given:
    - a per-run SQLite store was opened by a worker with an old fence token
    - another owner has acquired the run with a newer fence token
  when:
    - the old store attempts to save a standalone fact row
  then:
    - the write is rejected before the SQLite `facts` table changes
    - later lazy fact resolution sees the value written by the current owner, if any
  covers:
    - workflows.storage.fact_level_persistence
    - workflows.storage.fenced_fact_writes

- id: workflows.storage.fact_hash_conflict_preserves_content
  given:
    - a fact row already exists for hash H
  when:
    - a later write attempts to store a different serialized value for H
  then:
    - the existing content is not overwritten
    - the writer either receives a conflict error or the write is treated as an idempotent no-op only if the content matches
  covers:
    - workflows.storage.fact_hash_immutability
```

## Verification

```spec-verification
- kind: doc_file
  target: docs/plans/durable-workflow-system-design.md
  covers:
    - workflows.storage.one_to_one_sqlite
    - workflows.storage.checkpoint_format
    - workflows.storage.checkpoint_strategies
    - workflows.storage.passivation_tiers
    - workflows.storage.rehydration_modes
    - workflows.storage.litestream_replication
    - workflows.storage.litestream_directory_layout
    - workflows.storage.litestream_restore
    - workflows.storage.schema_versioning
    - workflows.storage.checkpoint_and_restore
    - workflows.storage.passivation_to_cold
    - workflows.storage.wal_checkpoint_failure_preserves_local_files
    - workflows.storage.cold_restore_from_s3
    - workflows.storage.schema_migration_on_wake
    - workflows.storage.litestream_auto_discovery

- kind: doc_file
  target: docs/plans/runic-research.md
  covers:
    - workflows.storage.checkpoint_format
    - workflows.storage.checkpoint_strategies
    - workflows.storage.fact_level_persistence
    - workflows.storage.rehydration_modes
    - workflows.storage.checkpoint_and_restore

- kind: doc_file
  target: spec/decisions/per-execution-sqlite-store.md
  covers:
    - workflows.storage.one_to_one_sqlite
    - workflows.storage.checkpoint_format
    - workflows.storage.passivation_tiers
    - workflows.storage.passivation_preserves_uncheckpointed_files
    - workflows.storage.passivation_to_cold
    - workflows.storage.cold_restore_from_s3

- kind: source_file
  target: lib/fizz/workflows/store/sqlite_store.ex
  covers:
    - workflows.storage.checkpoint_format
    - workflows.storage.fact_level_persistence
    - workflows.storage.fenced_fact_writes
    - workflows.storage.fact_hash_immutability
    - workflows.storage.schema_versioning

- kind: source_file
  target: lib/fizz/workflows/passivation_sweeper.ex
  covers:
    - workflows.storage.passivation_tiers
    - workflows.storage.passivation_preserves_uncheckpointed_files

- kind: test_file
  target: test/fizz/workflows/store/sqlite_store_test.exs
  covers:
    - workflows.storage.checkpoint_and_restore
    - workflows.storage.fenced_standalone_fact_write
    - workflows.storage.fact_hash_conflict_preserves_content
    - workflows.storage.schema_migration_on_wake

- kind: test_file
  target: test/fizz/workflows/passivation_sweeper_test.exs
  covers:
    - workflows.storage.passivation_to_cold
    - workflows.storage.wal_checkpoint_failure_preserves_local_files
```

## Exceptions

```spec-exceptions
- id: workflows.storage.impl_pending
  note: Hybrid and lazy rehydration modes are not yet implemented. The ARCHIVE tier (S3 Glacier for completed executions) is not yet implemented. All other storage contracts — checkpoint format, checkpoint strategies, passivation tiers (HOT/COLD), Litestream replication and restore, and schema versioning — are enforced in code.
  relates_to:
    - workflows.storage.fact_level_persistence
    - workflows.storage.rehydration_modes
```
