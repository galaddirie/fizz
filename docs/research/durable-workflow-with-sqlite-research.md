# Building a durable workflow engine on per-instance SQLite

**A SQLite database per workflow instance can serve as a complete durable execution substrate—event store, snapshot store, timer table, dedup registry, and outbox—if wrapped by a coordination layer that enforces single-writer ownership, deterministic replay, and a global routing index.** The architecture draws proven patterns from Temporal, Azure Durable Functions, Restate, and DBOS while exploiting SQLite's unique properties: ACID transactions with zero network overhead, WAL-mode concurrent reads during replay, and a single-writer constraint that is not a limitation but a structural guarantee of per-shard linearizability. Cloudflare Durable Objects already runs this model at massive scale—one SQLite database per object, single-threaded execution, hibernation to cold storage, durable alarms—validating the core architecture. What follows is the complete design across all nine required subsystems, grounded in production-proven patterns and specific SQLite implementation details.

---

## SQLite is the ideal embedded substrate for workflow state

SQLite in WAL mode provides the foundational properties a per-workflow durable store needs. **Writers append to a sequential log file while readers access consistent snapshots without blocking**—exactly the concurrency profile of a workflow engine that replays event history (read-heavy) while concurrently appending new events (write). Performance is compelling: batched sequential appends achieve **~80,000–100,000 inserts/second** in WAL mode with `synchronous=NORMAL`, and indexed range scans over event histories return in sub-millisecond time even at millions of rows.

The single-writer constraint—only one connection can write at any instant—maps directly onto the single-owner-per-workflow model that all major workflow engines enforce. Rather than fighting this constraint with complex concurrency control, the architecture embraces it: each workflow's SQLite file has exactly one owning process at any time, making fence-check-and-write operations naturally atomic within a single transaction. No distributed locks, no optimistic concurrency retries—just SQLite's built-in serialization.

The recommended per-workflow SQLite configuration:

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA cache_size = -32000;     -- 32MB page cache
PRAGMA mmap_size = 268435456;   -- 256MB memory-mapped I/O
PRAGMA wal_autocheckpoint = 0;  -- managed externally by Litestream or engine
```

Disabling autocheckpoint is critical when using Litestream for replication, as Litestream takes over checkpoint management by holding a read transaction that monitors WAL growth.

**Cloudflare Durable Objects validates this architecture at production scale.** Each DO gets a private, embedded SQLite database (up to 10GB) with synchronous SQL access in the same thread. Writes replicate to five follower machines with three-of-five confirmation before an output gate releases the response to clients. The alarm API provides durable timers. Hibernation evicts idle DOs from memory while preserving SQLite state. Point-in-time recovery covers the last 30 days. Millions of DOs run globally, each with complete isolation.

For durability beyond a single node, **Litestream** streams WAL frames to S3/GCS in near-real-time (sub-second replication lag, ~$1/month storage cost), enabling disaster recovery by restoring the latest snapshot plus WAL segments. **LiteFS** provides live read replicas via FUSE-based transaction shipping with Consul-based leader election. **rqlite** and **dqlite** offer Raft-based strong-consistency replication at the cost of write throughput (~1,000–3,000 single-transaction writes/second due to consensus overhead). For the per-workflow-SQLite model, Litestream provides the best cost-complexity tradeoff: single-writer durability with S3 backup, no operational overhead of running a Raft cluster per shard.

---

## Deterministic execution replay is the engine's core invariant

Every major workflow engine—Temporal, Azure Durable Functions, Restate, DBOS—shares a single architectural insight: **separate deterministic control flow from non-deterministic side effects, record side-effect results durably, and replay the deterministic code against recorded results to reconstruct state after failures.** The systems differ in how strictly they enforce this separation and how replay mechanically works.

**Temporal's model** is the strictest and most instructive. Workflow code must be fully deterministic—no `time.Now()`, no `rand.Int()`, no I/O, no network calls. The TypeScript SDK enforces this by running workflow code in a sandboxed V8 isolate where `Math.random()`, `Date`, and `setTimeout` are replaced with deterministic versions; `WeakRef` and `FinalizationRegistry` are removed because garbage collection is non-deterministic. The Go SDK provides a static analysis tool (`workflowcheck`). All side effects must occur in Activities—separate functions dispatched to workers via task queues.

During execution, the SDK emits Commands (e.g., `ScheduleActivityTask`, `StartTimer`). The server converts Commands into Events and appends them to an ordered, immutable Event History. When a workflow resumes—after a crash, timer fire, or signal—a worker requests the full history and **replays the workflow function from the beginning**. For each Command the replaying code would emit, the SDK checks for a matching Event in history. If `ScheduleActivityTask("charge_payment")` matches an existing `ActivityTaskScheduled` + `ActivityTaskCompleted` pair, the SDK returns the recorded result immediately without re-executing the activity. When replay exhausts recorded history, new Commands produce real side effects. If a Command doesn't match the expected Event, a non-determinism error fires.

**Restate takes a lighter approach.** There is no mandatory activity/workflow split. Any handler can perform side effects by wrapping them in `ctx.run(fn)`, which journals the result. Determinism is required only in the control flow between `ctx.*` calls. On retry, the server sends the full journal; the SDK replays each journaled call, returning stored results until the journal is exhausted. Fencing via epoch numbers prevents stale execution attempts from writing conflicting results.

**DBOS uses the simplest model:** annotate functions with `@DBOS.step()` for checkpointed side effects. On recovery, DBOS calls the workflow again, and each step checks Postgres for a stored output before executing. For database operations specifically, DBOS achieves true exactly-once semantics by executing the step and recording the checkpoint in a single Postgres transaction.

For a SQLite-based engine, the Temporal-style replay model maps naturally. The workflow's SQLite database stores the event history. On resume, the engine loads events and replays the workflow function, matching Commands against recorded Events. The replay code path is read-heavy—scanning events by `(workflow_id, sequence_num)`—which WAL mode serves excellently without blocking any concurrent writer.

---

## Event sourcing plus snapshots enable efficient resume after years of dormancy

A workflow dormant for months or years must resume without replaying its entire event history. The solution combines **event sourcing** (append-only event log as source of truth) with **periodic snapshots** (serialized workflow state at a point in the log) so that resume loads the latest snapshot and replays only subsequent events.

The core SQLite schema for a per-workflow database:

```sql
CREATE TABLE events (
    event_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    sequence_num INTEGER NOT NULL UNIQUE,
    event_type   TEXT    NOT NULL,
    payload      BLOB,
    timestamp    INTEGER NOT NULL
);

CREATE TABLE snapshots (
    sequence_num     INTEGER PRIMARY KEY,
    state_data       BLOB    NOT NULL,
    snapshot_version INTEGER NOT NULL DEFAULT 1,
    created_at       INTEGER NOT NULL
);
```

The resume algorithm: load the latest snapshot, deserialize state (upcasting if the snapshot format version differs from the current code), then replay only events where `sequence_num > snapshot.sequence_num`. For a workflow passivated with a fresh snapshot, this is **O(1)**—zero events to replay regardless of dormancy duration.

**Snapshot frequency strategy matters.** The recommended approach for workflow engines is a hybrid: take a snapshot **on passivation** (the workflow is being evicted from memory anyway, so serialization cost is amortized) combined with **every-N-events** as a safety net for long-running workflows that stay resident. Temporal enforces a hard limit of **50,000 events / 50MB per execution** and provides `ContinueAsNew` to carry forward state into a fresh execution with a clean history. A SQLite-based engine should adopt similar bounds, snapshotting every 1,000 events and compacting older events after the snapshot.

Event compaction after snapshotting is optional but valuable for storage efficiency:

```sql
DELETE FROM events WHERE sequence_num <= (
    SELECT MAX(sequence_num) FROM snapshots
);
```

For workflows that accumulate hundreds of thousands of events (e.g., high-frequency trading monitors), compaction keeps the SQLite file size bounded and replay times predictable.

---

## Ownership and lease coordination enforce single-writer safety

The most critical coordination requirement: **exactly one process may write to a given workflow's SQLite database at any time.** This is enforced through a lease-based ownership protocol combined with fencing tokens that provide safety even when leases are imprecise.

A process acquires a time-limited lease (e.g., 30-second TTL) from a coordination service—etcd, ZooKeeper, or a PostgreSQL-backed lease table. The lease includes a **monotonically increasing fencing token** (etcd's key revision, Raft's term number, or an auto-incrementing integer). The process must renew the lease before expiry; if it crashes or pauses, the lease expires and another process can claim ownership.

**Leases alone are insufficient for safety**, as Martin Kleppmann demonstrated: a process can pause (GC, page fault, network delay) after acquiring the lease but before completing its write. During the pause, the lease expires, another process acquires a new lease with a higher fencing token, and the original stale process resumes and issues a conflicting write. The fencing token prevents this: every write transaction validates that its token is not stale.

```sql
CREATE TABLE shard_fence (
    shard_id    TEXT PRIMARY KEY,
    fence_token INTEGER NOT NULL
);
```

The write path within a SQLite transaction: check that the fence token in `shard_fence` is not higher than the writer's token, update the fence token, then perform the actual event append—all atomically. Because SQLite serializes all writes, this check-and-write is inherently linearizable within a single database file. No external distributed lock is needed at the storage layer.

For the coordination service itself, **etcd** provides the simplest production-grade option: built-in lease primitives with TTL, key revision numbers as natural fencing tokens, and watch APIs for detecting ownership changes. A PostgreSQL-backed lease table works well for systems already running Postgres for the global index:

```sql
UPDATE shard_leases
SET owner_id = :new_owner,
    fence_token = fence_token + 1,
    lease_expiry = NOW() + INTERVAL '30 seconds'
WHERE shard_id = :shard_id
  AND (lease_expiry < NOW() OR owner_id = :new_owner);
```

For higher availability, a **Raft group per shard** (the Multi-Raft pattern used by CockroachDB and TiKV) provides automatic leader election with sub-second failover. Raft term numbers serve as fencing tokens. Libraries like Dragonboat support thousands of Raft groups per node, sharing network I/O and storage across groups. However, this adds significant complexity; for most deployments, etcd-based leasing with fencing tokens provides adequate safety with far less operational burden.

---

## Durable timers survive crashes and years of dormancy

When a workflow calls `sleep(365 days)`, the engine persists a timer row in the workflow's SQLite database, passivates the workflow to cold storage, and relies on a separate timer service to fire the timer a year later.

```sql
CREATE TABLE timers (
    timer_id    TEXT PRIMARY KEY,
    fire_at     TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'PENDING',
    payload     BLOB
);
CREATE INDEX idx_timers_pending ON timers(fire_at) WHERE status = 'PENDING';
```

The **partial index** on `fire_at WHERE status = 'PENDING'` is critical: as timers fire and transition to `FIRED` status, they automatically leave the index, keeping scan performance constant regardless of how many historical timers exist.

The timer service operates at the **control plane level**, not within individual workflow SQLite databases. It maintains a lightweight global table (in PostgreSQL or a dedicated SQLite) mapping `(workflow_id, next_timer_fire_at)` for all workflows with pending timers. A polling loop scans for due timers:

1. Query: `SELECT workflow_id FROM global_timers WHERE fire_at <= NOW() AND status = 'PENDING' ORDER BY fire_at LIMIT 100`
2. For each due timer: mark as `FIRING`, trigger workflow wake-up
3. The wake-up process downloads the workflow's SQLite from cold storage, replays from the latest snapshot, delivers the `TIMER_FIRED` event, and resumes execution

**Temporal's approach confirms this pattern works at scale.** Sleeping workflows consume zero worker resources—the server tracks fire times in its persistence layer. When a timer fires, the server schedules a Workflow Task, a worker picks it up, replays the event history, and resumes. This handles arbitrarily long durations. Cloudflare Durable Objects uses a similar model with its Alarm API: `ctx.storage.setAlarm(scheduledTime)` stores the wake-up time durably, and multiple fault-tolerant processes per datacenter track alarms with automatic retry on failure.

For the wake-up-from-cold-storage path, latency depends on SQLite file size. A typical workflow database of **100KB–10MB** downloads from S3 in 50–200ms, with snapshot-based replay adding negligible time. Total cold-start latency of **200ms–2 seconds** is achievable. Pre-warming strategies—downloading the SQLite file a few minutes before the timer fires—can reduce this further.

---

## Signal deduplication converts at-least-once delivery to exactly-once processing

External signals reach workflows through an ingestion path that must handle three challenges: the workflow may be dormant, the signal may be delivered more than once, and the signal must be durably recorded before acknowledgment.

The architecture uses a **signal inbox** at the control plane level (in the global PostgreSQL database, not the per-workflow SQLite, since the workflow's SQLite may be in cold storage):

```sql
CREATE TABLE signal_inbox (
    signal_id   TEXT PRIMARY KEY,
    workflow_id TEXT NOT NULL,
    signal_name TEXT NOT NULL,
    payload     BLOB,
    received_at TIMESTAMP DEFAULT NOW(),
    delivered   BOOLEAN DEFAULT FALSE
);
```

When a signal arrives: write to `signal_inbox`, then check the global index for the workflow's status. If active, notify the owning worker directly. If passivated, enqueue a wake-up task. The wake-up process loads the SQLite, replays state, reads pending signals from the inbox in order, delivers them to the workflow's signal handlers, and marks them as delivered.

**Deduplication** uses the `signal_id` as a natural deduplication key. Callers include a unique identifier (UUID, or a deterministic composite key like `{source}-{entity_id}-{operation_sequence}`). The `PRIMARY KEY` constraint on `signal_id` rejects duplicates at the database level. Within the per-workflow SQLite, a `processed_signals` table provides a second layer of dedup:

```sql
CREATE TABLE processed_signals (
    signal_id    TEXT PRIMARY KEY,
    processed_at INTEGER NOT NULL
);
```

The check-process-record cycle happens within a single SQLite transaction, making it atomic thanks to the single-writer model. True exactly-once delivery is impossible (the Two Generals Problem), but **at-least-once delivery combined with idempotent processing produces effectively-exactly-once semantics**—the same pattern used by Temporal, where `WorkflowExecutionSignaled` events are recorded in the event history and replayed deterministically.

---

## Activities are dispatched, recorded, and replayed with idempotency keys

Activities—the side-effecting operations that workflows orchestrate—follow a dispatch-record-replay cycle. When workflow code calls `execute_activity("charge_payment", args)`, the engine:

1. Records an `ActivityScheduled` event in the workflow's SQLite
2. Writes an activity task to a **durable task queue** (a table in PostgreSQL or a shared SQLite, since the task must be visible to any worker in the pool)
3. A worker long-polls the queue, picks up the task, executes the activity function
4. On completion, the worker reports the result; the engine records `ActivityCompleted` with the serialized result in the workflow's SQLite
5. On **replay**, the workflow encounters the activity call and immediately returns the stored result—no re-execution

The critical failure mode: a worker completes an activity (charges a credit card) but crashes before reporting the result. The engine times out and retries the activity. Without idempotency, the card is charged twice. **Idempotency keys** solve this: each activity invocation includes a deterministic key (e.g., `{workflow_id}-{activity_sequence}-{attempt_number}`) passed to the external service, which deduplicates on its end.

```python
def charge_payment(ctx, order_id, amount):
    idempotency_key = f"{ctx.workflow_id}-{ctx.activity_id}-{ctx.attempt}"
    return payment_api.charge(
        order_id=order_id,
        amount=amount,
        idempotency_key=idempotency_key
    )
```

**Retry policies** follow Temporal's proven model: configurable initial interval, exponential backoff coefficient, maximum interval cap, maximum attempts, and a list of non-retryable error types. `StartToCloseTimeout` bounds individual attempts; `ScheduleToCloseTimeout` bounds the entire activity including all retries. For long-running activities (ML training, large file processing), **heartbeating** lets the worker report progress and checkpoint data. If the worker crashes, the next attempt receives the last heartbeat payload and can resume from the checkpoint rather than starting over.

The **outbox pattern** bridges the gap between the per-workflow SQLite and external message brokers. Activity completion and outbox message are written in the same SQLite transaction. A separate publisher process reads unpublished outbox entries and pushes them to the broker, marking them as published. Since the broker publish may fail, downstream consumers must be idempotent—closing the exactly-once loop at every boundary.

---

## A global index routes signals and wakes dormant workflows

The control plane maintains a **global index** mapping every workflow instance to its current location, status, and metadata. This is the routing backbone that enables the system to locate any workflow—active, dormant, or passivated to cold storage—and deliver signals, timer fires, and queries to it.

PostgreSQL is the recommended backing store for up to ~10 million workflows (rich SQL queries, LISTEN/NOTIFY for change propagation, mature tooling). CockroachDB extends this to multi-region deployments. The index stores:

- `workflow_id` (primary key), `workflow_type`, `namespace`/`tenant_id`
- `node_id` (current owning worker), `status` (RUNNING, DORMANT, PASSIVATED, COMPLETED)
- `storage_uri` (S3 path when passivated), `last_active_time`, `next_timer_fire`
- Custom search attributes (business keys like `customer_id`, `order_amount`)

**Routing flow:** A stateless frontend service receives all inbound requests. It queries the global index for the target `workflow_id`. If the workflow is active on a node, the request forwards directly. If passivated, the frontend selects an available worker, triggers the wake-up process (download SQLite from S3, replay from snapshot, update index), and delivers the request.

**Explicit shard assignment** (storing the owning `node_id` directly in the index) is preferred over pure consistent hashing. It allows capacity-aware placement, manual migration, and affinity-based routing while using consistent hashing only as a default initial placement strategy for new workflows. Temporal uses a similar approach internally: workflow IDs hash to one of N History Shards, but ownership of shards to History Service instances is tracked explicitly via a membership protocol.

**Passivation to cold storage** follows a tiered model. Active workflows live on worker SSDs with SQLite files open. After a configurable inactivity threshold (e.g., 10 minutes), the engine checkpoints the WAL (`PRAGMA wal_checkpoint(TRUNCATE)`), takes a snapshot, uploads the SQLite file to S3, updates the global index to `PASSIVATED`, and releases the file. Wake-up from S3 for a typical 1–10MB SQLite file completes in **200ms–2 seconds**. An LRU cache on each worker keeps recently active workflows warm on local SSD (fast re-open, zero RAM) before full eviction to object storage.

**Managing millions of SQLite files** requires filesystem discipline. A two-level hash prefix directory structure (`/data/workflows/{namespace}/{2-char-prefix}/{2-char-prefix}/{workflow_id}.sqlite`) keeps directory sizes below 4,000 entries. Each open SQLite in WAL mode consumes ~3 file descriptors (main DB, WAL, SHM); 10,000 active workflows per node requires ~30,000 FDs, well within a `ulimit -n 65536` setting. Idle workflows should be aggressively closed, with only actively-executing workflows holding open file handles.

---

## State versioning lets workflows resume safely across software upgrades

When workflow code changes while workflows are in-flight, replay with new code may produce different Commands than the recorded Event History expects—causing non-determinism errors. Three proven strategies address this.

**Patching (Temporal's `GetVersion`)** is the most fine-grained approach. A version marker event is recorded at the branch point in the history. During replay, if the marker exists, the recorded version determines which code path executes. For new executions, the latest version is used. This allows old and new code paths to coexist in a single codebase:

```python
v = workflow.get_version("payment-v2", DEFAULT_VERSION, 1)
if v == DEFAULT_VERSION:
    result = await workflow.execute_activity(charge_v1, amount)
else:
    result = await workflow.execute_activity(charge_v2, amount, currency)
```

**Worker versioning** pins workflows to the deployment version that started them. Old workers run old code; new workers run new code. The routing layer directs Workflow Tasks to the correct worker version. This avoids code branching but requires keeping old deployments alive until all their workflows complete—Restate uses this as its primary versioning mechanism.

**DBOS's source-code hashing** automatically computes a version from workflow source code at startup and only recovers workflows matching the current version. Running old code versions requires starting a process with that code.

**Safe changes** that don't require versioning include modifying activity timeout/retry options, changing activity function bodies (not workflow orchestration code), and adding signal handlers for unsent signal types. **Breaking changes** that require versioning include adding, removing, or reordering activity calls, timer/sleep calls, or child workflow invocations—anything that changes the sequence of Commands.

**SQLite schema evolution** for long-lived workflows uses the `PRAGMA user_version` mechanism. Each SQLite file stores a schema version integer in its header. On wake-up, the engine reads `user_version`, runs any pending migrations sequentially within transactions, and updates the version:

```python
def open_workflow_db(path):
    db = sqlite3.connect(path)
    current = db.execute("PRAGMA user_version").fetchone()[0]
    for version, migrate_fn in MIGRATIONS:
        if current < version:
            with db:
                migrate_fn(db)
                db.execute(f"PRAGMA user_version = {version}")
    return db
```

Migrations must be idempotent (`IF NOT EXISTS` guards), forward-only, and atomic. If the database version is higher than the code knows, the engine must refuse to open it—preventing data corruption from running old code against a newer schema. For snapshot format evolution, snapshots include a `snapshot_version` field, and the engine upcasts older snapshot formats to the current version during deserialization.

---

## Observability enables time-travel debugging of workflows dormant for years

Per-workflow SQLite databases provide a unique observability advantage: **any workflow's complete state can be inspected offline by downloading its SQLite file from cold storage and querying it with standard SQL tools**—no running engine required, no risk of side effects, no wake-up cost.

Time-travel debugging is native to event-sourced architectures. To inspect a workflow's state at any point: load the latest snapshot before the target sequence number, replay events from the snapshot through the target, and examine the reconstructed state. This works identically on a live system or on a downloaded SQLite file opened in read-only mode (`sqlite3 "file:workflow.db?mode=ro"`).

The global index in PostgreSQL supports Temporal-style **visibility queries** with custom search attributes. Operators can filter workflows by type, status, time range, customer ID, or any business key indexed as a search attribute. The recommended operator API surface (modeled on Temporal's proven design):

- **Describe**: metadata, status, pending activities/timers, current search attributes
- **List/Count**: SQL-like filtering across all workflows in the global index
- **Get History**: full event log from the per-workflow SQLite
- **Signal/Query/Update**: interact with live or dormant workflows
- **Reset**: rewind to a specific event and re-execute (powerful for bug recovery)
- **Terminate/Cancel**: force-stop or graceful shutdown

**Key metrics to export** (via Prometheus/OpenTelemetry): workflow task schedule-to-start latency, activity execution latency, pending activity and timer counts, event history length, SQLite file size, cold-start wake-up latency, passivation rate, and worker active-workflow count. Distributed tracing propagates `trace_id` through event payloads, creating spans for workflow execution, each activity invocation, signal processing, and timer fires.

Cloudflare Durable Objects adds built-in point-in-time recovery: any object can be reverted to its state at any point in the last 30 days using lexically comparable bookmark strings. A SQLite-based engine can provide similar capability by retaining Litestream WAL segments in S3, enabling restore to any point covered by the retention window.

---

## Conclusion: the architecture that emerges

The complete system comprises three layers. The **data plane** is a set of worker nodes, each running workflow instances with per-instance SQLite databases in WAL mode—serving as event store, snapshot store, timer table, dedup registry, and outbox in a single file. The **coordination layer** (etcd or PostgreSQL-backed leases with fencing tokens) enforces single-writer ownership per workflow. The **control plane** (PostgreSQL global index, stateless frontend, timer service) routes requests, tracks workflow locations, manages passivation to S3, and fires durable timers.

The architecture's deepest insight is that **SQLite's single-writer constraint eliminates an entire class of distributed coordination problems within a shard.** Fence validation, deduplication checks, event appends, snapshot writes, and outbox entries all execute atomically in a single SQLite transaction with zero network hops. The coordination challenge shifts entirely to the shard-to-owner mapping—a much simpler problem solved by leases and fencing tokens.

Three design decisions have outsized impact on production viability. First, **snapshotting on passivation** ensures that dormant workflows resume in O(1) time regardless of how long they slept—the snapshot is always fresh when cold storage is the last stop. Second, **the global timer service operating on a metadata table** (not scanning individual SQLite files) enables efficient scheduling across millions of dormant workflows. Third, **migration-on-wake with `user_version`** means that long-dormant SQLite databases transparently upgrade their schema when loaded, even after years of dormancy spanning multiple software releases.

The risk profile centers on three areas: **split-brain writes** (mitigated by fencing tokens as the ultimate safety net, even if lease timing is imprecise), **cold-start latency** (bounded by keeping SQLite files small through snapshot compaction and `ContinueAsNew`-style history truncation), and **global index availability** (mitigated by running PostgreSQL with streaming replication or using CockroachDB for multi-region deployments). The academic foundations are solid: Burckhardt et al.'s OOPSLA 2021 paper provides formal semantics for durable function replay, and the Netherite paper (VLDB 2022) demonstrates order-of-magnitude performance gains from event-sourcing with asynchronous snapshots—exactly the pattern this architecture employs, with SQLite replacing FASTER as the embedded store.