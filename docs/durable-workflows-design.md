# Durable Workflow Platform: Complete System Design

**Elixir · Phoenix · Runic · SQLite · S3 · Postgres**

---

## 1. Requirements

### Functional

- **Long-lived workflows**: orchestrations that sleep for minutes, months, or years and resume correctly after arbitrary dormancy.
- **Durable execution**: every state transition survives process crashes, node failures, and rolling deploys. No silent data loss.
- **Activity orchestration**: workflows dispatch side-effecting "activities" (HTTP calls, payments, ML jobs) with configurable retry policies, timeouts, and heartbeating.
- **Signals and queries**: external systems can send named signals into running or dormant workflows and query their current state without waking them.
- **Durable timers**: `sleep(duration)` and `schedule_at(datetime)` persist to storage and fire reliably even if the originating node is long gone.
- **Organization + project isolation**: hard isolation of workflow data per WorkOS organization and local project, with scoped quotas, routing, and observability.
- **Operator tooling**: list, search, describe, signal, cancel, reset, and time-travel-debug any workflow via a Phoenix LiveView console.

### Non-functional

- **Consistency**: exactly-once *progression* of workflow state (each step advances the event log at most once). At-least-once *execution* of activities, with idempotency contracts at service boundaries.
- **Latency**: < 50 ms for a warm workflow step transition. < 2 s cold-start from S3 for a passivated workflow (target ≤ 10 MB SQLite file).
- **Throughput**: ≥ 10,000 concurrent active workflows per node; millions of dormant workflows system-wide.
- **Durability**: zero acknowledged work lost, even under simultaneous node failure and S3 partition (bounded by RPO of Litestream replication lag, typically < 1 s).
- **Operability**: structured logging, distributed tracing (OpenTelemetry), Prometheus metrics, health checks, graceful deployment with zero-downtime drains.

### Fizz Repo Mapping

The research notes use **tenant** as a generic isolation term. In this repo, that maps onto the existing identity model:

- **WorkOS organization** is the outer isolation, billing, credential, and audit boundary.
- **Project** is the main local resource boundary for workflows, workspaces, jobs, and authorization.
- Workflow control-plane rows should therefore persist both `workos_organization_id` and `project_id`, rather than a single generic `tenant_id`.
- Workflow operations should resolve authorization through `%Fizz.Accounts.Scope{}` and `Accounts.build_scope_for_project/2`, matching `Fizz.Workspaces` and `Fizz.Integrations`.
- If a workflow orchestrates work inside a workspace, treat `workspace_id` as optional workflow metadata, not as the primary isolation key.
- The workflow domain itself should live under `Fizz.Workflows.*` (`Fizz.Workflows.WorkflowRun`, `Fizz.Workflows.RunWorker`, `Fizz.Workflows.SignalInbox`, etc.), while LiveViews/controllers remain under `FizzWeb.*` and call into that domain.
- The first operator UI should be project-scoped, e.g. `/projects/:project_id/workflows`, inside the existing authenticated browser scope / `live_session :require_authenticated_user`, because those routes already provide `@current_scope` and match the rest of the app.

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CONTROL PLANE (Postgres)                     │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐  ┌───────────┐ │
│  │ Global Index  │  │ Lease Table  │  │ Timer Svc  │  │ Signal    │ │
│  │ (routing,     │  │ (ownership,  │  │ (durable   │  │ Inbox     │ │
│  │  search,      │  │  fencing)    │  │  wakeups)  │  │ (dedup,   │ │
│  │  org/project  │  │              │  │            │  │  delivery) │ │
│  │  scope)       │  │              │  │            │  │            │ │
│  └──────┬───────┘  └──────┬───────┘  └─────┬──────┘  └─────┬─────┘ │
│         │                 │                │              │         │
│         └────────────┬────┴────────────────┴──────────────┘         │
│                      │  LISTEN / NOTIFY                             │
└──────────────────────┼──────────────────────────────────────────────┘
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
   ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
   │  Worker Node │ │  Worker Node │ │  Worker Node │
   │  (Elixir)    │ │  (Elixir)    │ │  (Elixir)    │
   │             │ │             │ │             │
   │ ┌─────────┐ │ │ ┌─────────┐ │ │ ┌─────────┐ │
   │ │ Runic   │ │ │ │ Runic   │ │ │ │ Runic   │ │
   │ │ Workers │ │ │ │ Workers │ │ │ │ Workers │ │
   │ │ (GenSrv)│ │ │ │ (GenSrv)│ │ │ │ (GenSrv)│ │
   │ └────┬────┘ │ │ └────┬────┘ │ │ └────┬────┘ │
   │      │      │ │      │      │ │      │      │
   │ ┌────▼────┐ │ │ ┌────▼────┐ │ │ ┌────▼────┐ │
   │ │ SQLite  │ │ │ │ SQLite  │ │ │ │ SQLite  │ │
   │ │ (WAL)   │ │ │ │ (WAL)   │ │ │ │ (WAL)   │ │
   │ │ per-run │ │ │ │ per-run │ │ │ │ per-run │ │
   │ └────┬────┘ │ │ └────┬────┘ │ │ └────┬────┘ │
   │      │      │ │      │      │ │      │      │
   │ ┌────▼────┐ │ │ ┌────▼────┐ │ │ ┌────▼────┐ │
   │ │Litestrm │ │ │ │Litestrm │ │ │ │Litestrm │ │
   │ │ → S3    │ │ │ │ → S3    │ │ │ │ → S3    │ │
   │ └─────────┘ │ │ └─────────┘ │ │ └─────────┘ │
   └─────────────┘ └─────────────┘ └─────────────┘
          │                │               │
          └────────────────┼───────────────┘
                           ▼
                    ┌─────────────┐
                    │  S3 / GCS   │
                    │ (cold store,│
                    │  WAL archive│
                    │  ~$1/mo)    │
                    └─────────────┘

   ┌──────────────────────────────────────────────┐
   │          Phoenix LiveView Console             │
   │  (list · search · describe · signal · reset)  │
   └──────────────────────────────────────────────┘
```

**Three-layer summary.** The *data plane* is worker nodes running Runic workflow GenServers, each backed by a node-local SQLite database in WAL mode. Litestream continuously replicates WAL frames to S3 for durability. The *coordination layer* is Postgres-backed leases with fencing tokens, enforcing single-writer ownership per workflow. The *control plane* is Postgres tables (global index, timer service, signal inbox) plus a stateless Phoenix frontend and operator console.

The deepest structural insight: SQLite's single-writer constraint eliminates an entire class of distributed coordination problems *within* a workflow shard. Fence validation, deduplication checks, event appends, snapshot writes, and outbox entries all execute atomically in one SQLite transaction with zero network hops. The coordination challenge reduces to shard-to-owner mapping — a much simpler problem solved by leases and fencing tokens in Postgres.

---

## 3. OTP Supervision Tree

```
Application
├── Repo (Ecto / Postgres)
│
├── Fizz.Workflows.Supervisor                 (one_for_one)
│   ├── Fizz.Workflows.ControlPlane.Supervisor (rest_for_one)
│   │   ├── Fizz.Workflows.LeaseManager       (GenServer — renews Postgres leases)
│   │   ├── Fizz.Workflows.TimerPoller        (GenServer — polls due timers via SKIP LOCKED)
│   │   ├── Fizz.Workflows.SignalRouter       (GenServer — drains signal_inbox, routes)
│   │   └── Fizz.Workflows.PassivationSweeper (GenServer — evicts idle workflows)
│   │
│   ├── Fizz.Workflows.DataPlane.Supervisor   (one_for_one)
│   │   ├── Registry (Fizz.Workflows.Registry) (unique keys: {project_id, run_id})
│   │   ├── PartitionSupervisor               (wraps Task.Supervisor, N partitions)
│   │   │   └── Task.Supervisor               (async_nolink for activity execution)
│   │   └── DynamicSupervisor (Fizz.Workflows.RunSupervisor)
│   │       └── Fizz.Workflows.RunWorker (GenServer) (one per active workflow)
│   │           ├── owns: Runic.Workflow (in-memory state)
│   │           ├── owns: SQLite connection (single-writer)
│   │           └── owns: Litestream child process (WAL → S3)
│
├── FizzWeb.Endpoint (Phoenix)
│   ├── Controllers / channels / LiveViews
│   └── LiveView operator console
│
└── Fizz.Workflows.Telemetry.Supervisor
    ├── :telemetry_poller (VM + custom metrics)
    └── OpenTelemetry exporter
```

**Key design decisions in the supervision tree:**

The `Fizz.Workflows.ControlPlane.Supervisor` uses `rest_for_one` so that if the `Fizz.Workflows.LeaseManager` crashes, the `Fizz.Workflows.TimerPoller` and `Fizz.Workflows.SignalRouter` also restart — they depend on valid leases. `Fizz.Workflows.DataPlane.Supervisor` uses `one_for_one` because individual workflow crashes are independent. `PartitionSupervisor` wraps `Task.Supervisor` to spread activity tasks across schedulers, avoiding bottlenecks on a single supervisor mailbox.

Each `Fizz.Workflows.RunWorker` is a GenServer that maps directly onto Runic's execution model. Runic's three-phase cycle — *prepare* (identify runnable nodes in the DAG), *execute* (dispatch to supervised tasks via `Task.Supervisor.async_nolink`), *apply* (fold results back into the workflow graph) — runs inside the GenServer's message loop. The "apply" phase is the single-writer state transition: it appends events to SQLite and advances the in-memory Runic workflow atomically. This separation means the "execute" phase can be treated as an isolated activity while "apply" becomes the linearizable state commit.

Runic's `Workflow.log/1` composes the build log, reaction history, and runnable lifecycle events (`RunnableDispatched`, `RunnableCompleted`, `RunnableFailed`) into a serializable list. `Workflow.from_log/1` replays those events to reconstruct the full graph. `Fizz.Workflows.RunWorker` uses these APIs for checkpointing and recovery, and `Workflow.pending_runnables/1` identifies dispatched-but-unresolved work after a crash, enabling re-dispatch without re-executing completed steps.

---

## 4. Data Model

### 4.1 Postgres — Control Plane Tables

```sql
-- Workflow registry and routing index
CREATE TABLE workflow_runs (
    run_id          UUID PRIMARY KEY,
    workos_organization_id TEXT NOT NULL,
    project_id      UUID NOT NULL REFERENCES projects(id),
    workflow_type   TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'PENDING'
                    CHECK (status IN ('PENDING','RUNNING','SLEEPING',
                                      'PASSIVATED','COMPLETED','FAILED',
                                      'CANCELLED')),
    owner_node      TEXT,                  -- node currently holding the lease
    fence_token     BIGINT NOT NULL DEFAULT 0,
    storage_uri     TEXT,                  -- s3://bucket/org/project/run_id.sqlite
    last_active_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    next_timer_at   TIMESTAMPTZ,           -- denormalized for timer polling
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    metadata        JSONB DEFAULT '{}'     -- search attributes, tags
);
CREATE INDEX idx_runs_org ON workflow_runs(workos_organization_id, status);
CREATE INDEX idx_runs_project ON workflow_runs(project_id, status);
CREATE INDEX idx_runs_owner  ON workflow_runs(owner_node) WHERE status = 'RUNNING';
CREATE INDEX idx_runs_timers ON workflow_runs(next_timer_at)
    WHERE next_timer_at IS NOT NULL AND status IN ('SLEEPING','PASSIVATED');

-- Lease table with fencing (can be unified with workflow_runs or separate)
CREATE TABLE shard_leases (
    run_id        UUID PRIMARY KEY REFERENCES workflow_runs(run_id),
    owner_node    TEXT NOT NULL,
    fence_token   BIGINT NOT NULL DEFAULT 0,
    lease_expiry  TIMESTAMPTZ NOT NULL,
    CONSTRAINT valid_expiry CHECK (lease_expiry > now())
);

-- Durable timers (denormalized from per-run SQLite for global polling)
CREATE TABLE durable_timers (
    timer_id      UUID PRIMARY KEY,
    run_id        UUID NOT NULL REFERENCES workflow_runs(run_id),
    workos_organization_id TEXT NOT NULL,
    project_id    UUID NOT NULL REFERENCES projects(id),
    fire_at       TIMESTAMPTZ NOT NULL,
    status        TEXT NOT NULL DEFAULT 'PENDING'
                  CHECK (status IN ('PENDING','FIRING','FIRED','CANCELLED')),
    payload       BYTEA
);
CREATE INDEX idx_timers_due ON durable_timers(fire_at)
    WHERE status = 'PENDING';

-- Signal inbox (write target for external systems, even when workflow is cold)
CREATE TABLE signal_inbox (
    signal_id     TEXT PRIMARY KEY,        -- caller-provided dedup key
    run_id        UUID NOT NULL,
    workos_organization_id TEXT NOT NULL,
    project_id    UUID NOT NULL REFERENCES projects(id),
    signal_name   TEXT NOT NULL,
    payload       BYTEA,
    received_at   TIMESTAMPTZ DEFAULT now(),
    delivered     BOOLEAN DEFAULT FALSE
);
CREATE INDEX idx_signals_pending ON signal_inbox(run_id)
    WHERE delivered = FALSE;

-- Activity task queue (multi-consumer with SKIP LOCKED)
CREATE TABLE activity_tasks (
    task_id         UUID PRIMARY KEY,
    run_id          UUID NOT NULL,
    workos_organization_id TEXT NOT NULL,
    project_id      UUID NOT NULL REFERENCES projects(id),
    runnable_id     TEXT NOT NULL,          -- Runic's {node.hash, fact.hash} id
    activity_type   TEXT NOT NULL,
    input           BYTEA,
    idempotency_key TEXT NOT NULL UNIQUE,   -- {run_id}-{runnable_id}-{attempt}
    status          TEXT NOT NULL DEFAULT 'PENDING'
                    CHECK (status IN ('PENDING','CLAIMED','COMPLETED','FAILED')),
    attempt         INTEGER NOT NULL DEFAULT 1,
    max_attempts    INTEGER NOT NULL DEFAULT 3,
    claimed_by      TEXT,
    claimed_at      TIMESTAMPTZ,
    timeout_at      TIMESTAMPTZ,
    result          BYTEA,
    error           JSONB,
    created_at      TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_tasks_claimable ON activity_tasks(activity_type, created_at)
    WHERE status = 'PENDING';
```

Suggested Ecto surface for the control plane:

- `Fizz.Workflows.WorkflowRun`
- `Fizz.Workflows.ShardLease`
- `Fizz.Workflows.DurableTimer`
- `Fizz.Workflows.SignalInbox`
- `Fizz.Workflows.ActivityTask`

The activity task queue uses Postgres `FOR UPDATE SKIP LOCKED` for multi-consumer claiming, which Postgres documentation explicitly recommends for queue-like tables where consumers should skip locked rows rather than blocking. In this repo, start by validating whether the existing Oban installation can own this responsibility before introducing a second bespoke queue table: `Fizz.Workspaces.ExecJob` already gives you a local pattern for durable Postgres-backed job execution, retries, and supervision.

### 4.2 SQLite — Per-Workflow Data Plane

Each workflow run gets its own SQLite file at `{data_dir}/{workos_organization_id}/{project_id}/{prefix1}/{prefix2}/{run_id}.sqlite`. The two-level hash-prefix directory structure keeps directory sizes below ~4,000 entries.

```sql
-- Applied on first open
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA cache_size = -8000;       -- 8 MB page cache (tuned per workload)
PRAGMA wal_autocheckpoint = 0;   -- Litestream manages checkpointing
PRAGMA user_version = 1;         -- schema version for migration-on-wake

-- Immutable, append-only event log (Runic build + reaction + runnable events)
CREATE TABLE events (
    event_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    sequence_num  INTEGER NOT NULL UNIQUE,
    event_type    TEXT NOT NULL,       -- 'component_added', 'reaction',
                                      -- 'runnable_dispatched', 'runnable_completed',
                                      -- 'runnable_failed', 'signal_received',
                                      -- 'timer_started', 'timer_fired',
                                      -- 'snapshot_taken'
    payload       BLOB NOT NULL,      -- :erlang.term_to_binary(event, [:compressed])
    timestamp_us  INTEGER NOT NULL    -- System.os_time(:microsecond)
);

-- Periodic snapshots for O(1) resume
CREATE TABLE snapshots (
    sequence_num      INTEGER PRIMARY KEY,
    state_data        BLOB NOT NULL,    -- serialized Runic.Workflow struct
    snapshot_version  INTEGER NOT NULL DEFAULT 1,
    created_at_us     INTEGER NOT NULL
);

-- Processed signal dedup (second layer, after Postgres inbox dedup)
CREATE TABLE processed_signals (
    signal_id     TEXT PRIMARY KEY,
    processed_at  INTEGER NOT NULL
);

-- Per-workflow timer records (canonical; Postgres has denormalized copies)
CREATE TABLE timers (
    timer_id   TEXT PRIMARY KEY,
    fire_at    TEXT NOT NULL,          -- ISO 8601
    status     TEXT NOT NULL DEFAULT 'PENDING',
    payload    BLOB
);
CREATE INDEX idx_timers_pending ON timers(fire_at) WHERE status = 'PENDING';

-- Fence token for single-writer validation
CREATE TABLE shard_fence (
    id          INTEGER PRIMARY KEY CHECK (id = 1),   -- singleton row
    fence_token INTEGER NOT NULL
);

-- Transactional outbox for reliable external publishing
CREATE TABLE outbox (
    outbox_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    topic        TEXT NOT NULL,
    payload      BLOB NOT NULL,
    published    BOOLEAN DEFAULT FALSE,
    created_at   INTEGER NOT NULL
);
CREATE INDEX idx_outbox_unpub ON outbox(outbox_id) WHERE published = FALSE;
```

**Configuration rationale.** Disabling `wal_autocheckpoint` is critical when Litestream manages replication: Litestream holds a read transaction to monitor WAL growth and takes over checkpoint scheduling. `synchronous=NORMAL` gives durability to committed transactions on the WAL (data survives process crash but not OS crash mid-write — Litestream's sub-second S3 replication covers the OS-crash window). WAL mode lets the Runic worker append events (write path) while concurrent readers (operator queries, metrics collection) access consistent snapshots without blocking.

---

## 5. Execution Semantics

### 5.1 Runic as the Execution Kernel

Runic serves as the workflow virtual machine. Its dataflow DAG with lazy evaluation and concurrency models "programs as data-driven workflows," supporting runtime composition — workflows can be extended and modified without requiring the full graph at compile time. The three-phase model is the critical enabler:

1. **Prepare**: `Workflow.plan_eagerly/1` walks the DAG and identifies nodes whose input facts are satisfied — these become `Runnable` structs.
2. **Execute**: runnables dispatch to `Task.Supervisor.async_nolink` (or to the Postgres activity queue for distributed execution). Each runnable carries a stable `id` derived from `{node.hash, fact.hash}`, which serves as a natural idempotency key.
3. **Apply**: task results return via `{ref, result}` and `:DOWN` messages. `Fizz.Workflows.RunWorker` folds results back into the workflow graph and appends lifecycle events (`RunnableCompleted`, `RunnableFailed`) to the SQLite event log — all within a single SQLite transaction.

This separation means the execute phase is an isolated, retriable operation, while the apply phase is the linearizable state commit.

### 5.2 The Step Lifecycle

```
                      ┌─────────────────────────────────┐
                      │ Fizz.Workflows.RunWorker GenServer │
                      │                                  │
  signal/timer ──────►│  1. Validate fence token         │
                      │  2. Replay from snapshot if cold │
                      │  3. Deliver event to Runic       │
                      │  4. plan_eagerly → runnables     │
                      │  5. Dispatch to Task.Supervisor  │
                      │          │                       │
                      │          ▼                       │
                      │  ┌──────────────┐                │
                      │  │  Activity    │  (at-least-    │
                      │  │  Execution   │   once)        │
                      │  └──────┬───────┘                │
                      │         │ result / error         │
                      │         ▼                        │
                      │  6. BEGIN SQLite txn             │
                      │     - check fence_token          │
                      │     - append RunnableCompleted   │
                      │     - update outbox              │
                      │     - maybe snapshot             │
                      │     COMMIT                       │
                      │                                  │
                      │  7. Ack Postgres activity_task   │
                      │  8. Advance Runic in-memory      │
                      │  9. plan_eagerly → loop to 5     │
                      └─────────────────────────────────┘
```

### 5.3 Idempotency and Exactly-Once Semantics

The system enforces a clear contract: **workflow state transitions are exactly-once with respect to the event log; external side effects are at-least-once and must be made idempotent.**

*Within the workflow boundary* (the SQLite file), exactly-once progression is guaranteed by the single-writer model. The fence-check-and-append happens in one SQLite transaction. If the process crashes after the COMMIT, replay via `Workflow.from_log/1` reconstructs the state including the committed event. If it crashes before COMMIT, the transaction rolls back atomically and `pending_runnables/1` identifies work that needs re-dispatch.

*At the activity boundary* (external services), idempotency keys close the loop:

```elixir
defmodule Fizz.Workflows.Activities.ChargePayment do
  @behaviour Fizz.Workflows.Activity

  @impl true
  def execute(%{run_id: run_id, runnable_id: rid, attempt: att}, args) do
    idempotency_key = "#{run_id}-#{rid}-#{att}"

    PaymentGateway.charge(
      amount: args.amount,
      currency: args.currency,
      idempotency_key: idempotency_key
    )
  end
end
```

Each activity invocation carries a deterministic key composed from `{run_id, runnable_id, attempt}`. Runic's stable runnable ID (derived from node and fact hashes) provides the `runnable_id` component. External services dedup on this key. The Postgres `activity_tasks` table enforces uniqueness on `idempotency_key` as a second layer.

### 5.4 Retry Policy

Retry configuration follows the proven Temporal model, applied per activity type:

```elixir
%RetryPolicy{
  initial_interval:    :timer.seconds(1),
  backoff_coefficient: 2.0,
  max_interval:        :timer.minutes(5),
  max_attempts:        5,
  non_retryable_errors: [InvalidInputError, AuthorizationError]
}
```

`start_to_close_timeout` bounds each individual attempt. `schedule_to_close_timeout` bounds the entire activity including all retries. For long-running activities, heartbeating lets the worker report progress and checkpoint data; if the worker crashes, the next attempt receives the last heartbeat payload and can resume from that checkpoint.

---

## 6. State Persistence Strategy

### 6.1 Event Sourcing + Snapshots

The per-workflow SQLite database is an event-sourced store. Every state transition appends an immutable event. Periodic snapshots serialize the full `Runic.Workflow` struct at a known sequence number, enabling O(1) resume by loading the latest snapshot and replaying only subsequent events.

**Resume algorithm:**

```elixir
def load_workflow(db) do
  # 1. Load latest snapshot
  {snap_seq, state_data, snap_version} =
    query(db, "SELECT sequence_num, state_data, snapshot_version
               FROM snapshots ORDER BY sequence_num DESC LIMIT 1")

  # 2. Upcast if snapshot format has changed
  workflow = Snapshot.deserialize(state_data, snap_version)

  # 3. Replay only events after the snapshot
  events =
    query(db, "SELECT payload FROM events
               WHERE sequence_num > ?1 ORDER BY sequence_num", [snap_seq])

  # 4. Fold events into the workflow (Runic's from_log reducer)
  Enum.reduce(events, workflow, &apply_event/2)
end
```

For a workflow passivated with a fresh snapshot, this is O(1) — zero events to replay regardless of dormancy duration.

**Snapshot frequency:** hybrid strategy — snapshot on passivation (the workflow is being evicted anyway, so serialization cost is amortized) plus every 1,000 events as a safety net for long-resident workflows. After snapshotting, older events can be compacted: `DELETE FROM events WHERE sequence_num <= (SELECT MAX(sequence_num) FROM snapshots)`.

**ContinueAsNew equivalent:** workflows that accumulate beyond 50,000 events or 50 MB should carry forward essential state into a fresh run with a clean history, preserving the parent run's SQLite as an archived artifact.

### 6.2 Passivation Tiers

```
Tier 0: HOT     — GenServer alive, SQLite open on local SSD
                   (active execution, < 50 ms step latency)

Tier 1: WARM    — GenServer stopped, SQLite file on local SSD
                   (LRU cache, re-open in < 10 ms, zero RAM)

Tier 2: COLD    — SQLite uploaded to S3, local file evicted
                   (download + replay in 200 ms – 2 s)

Tier 3: ARCHIVE — Run completed, SQLite in S3 Glacier
                   (operator inspection only, minutes to restore)
```

The `Fizz.Workflows.PassivationSweeper` GenServer runs a periodic scan (every 60 s) of active workflows via `Registry`. Workflows idle longer than the configured threshold (default 10 min) transition through tiers. On passivation to S3: checkpoint WAL (`PRAGMA wal_checkpoint(TRUNCATE)`), take a snapshot, upload, update Postgres `workflow_runs.status = 'PASSIVATED'` and `storage_uri`, release the file handle.

### 6.3 Litestream Replication

Each active SQLite file gets a Litestream replication process (managed as a Port or a sidecar) that continuously streams WAL frames to S3. Replication lag is typically sub-second; storage cost is roughly $1/month per workflow. This provides disaster recovery: if a node dies, the latest WAL frames are in S3. A new owner downloads the replicated database and resumes.

WAL mode is critical here, and SQLite's documentation explicitly warns that WAL mode does not work on network filesystems because the WAL-index uses shared memory. Our architecture avoids this entirely: SQLite files are always node-local. Cross-node failover works by downloading from S3, never by sharing a filesystem.

---

## 7. Ownership, Leasing, and Fencing

### 7.1 Lease Acquisition

When a node needs to own a workflow (new run, wake from cold, timer fire), it executes:

```sql
UPDATE shard_leases
SET owner_node  = :self,
    fence_token = fence_token + 1,
    lease_expiry = now() + interval '30 seconds'
WHERE run_id = :run_id
  AND (lease_expiry < now() OR owner_node = :self)
RETURNING fence_token;
```

`Fizz.Workflows.LeaseManager` renews all leases held by this node every 10 seconds (well within the 30 s TTL). If a node crashes, leases expire and another node can claim ownership.

### 7.2 Fencing Token Validation

Leases alone are insufficient for safety, as Martin Kleppmann demonstrated: a process can pause (GC, page fault, network delay) after acquiring the lease, the lease expires, another process acquires a higher token, and the stale process resumes. The fencing token prevents stale writes.

Every write transaction in SQLite validates the token:

```elixir
def append_event(db, fence_token, event) do
  Exqlite.transaction(db, fn ->
    # Validate fence — reject if a newer owner has written
    [{current_fence}] = query(db, "SELECT fence_token FROM shard_fence WHERE id = 1")

    if current_fence > fence_token do
      raise StaleOwnerError, "fence #{fence_token} < #{current_fence}"
    end

    # Update fence and append atomically
    execute(db, "UPDATE shard_fence SET fence_token = ?1 WHERE id = 1", [fence_token])
    execute(db, """
      INSERT INTO events (sequence_num, event_type, payload, timestamp_us)
      VALUES (?1, ?2, ?3, ?4)
    """, [next_seq, event.type, serialize(event), now_us()])
  end)
end
```

Because SQLite serializes all writes, this check-and-write is inherently linearizable within a single database file. No external distributed lock is needed at the storage layer.

---

## 8. Queueing and Backpressure

### 8.1 Activity Task Queue

The Postgres `activity_tasks` table serves as a durable, multi-consumer task queue. Workers long-poll with `FOR UPDATE SKIP LOCKED`:

```elixir
def claim_tasks(worker_node, activity_type, batch_size \\ 10) do
  Repo.query!("""
    UPDATE activity_tasks
    SET status = 'CLAIMED',
        claimed_by = $1,
        claimed_at = now(),
        timeout_at = now() + interval '5 minutes'
    WHERE task_id IN (
      SELECT task_id FROM activity_tasks
      WHERE status = 'PENDING' AND activity_type = $2
      ORDER BY created_at
      LIMIT $3
      FOR UPDATE SKIP LOCKED
    )
    RETURNING *
  """, [worker_node, activity_type, batch_size])
end
```

### 8.2 Backpressure Mechanisms

Backpressure operates at three levels:

**Worker level:** each `Fizz.Workflows.RunWorker` tracks in-flight activity count. When it reaches a configurable concurrency limit (e.g., 10 concurrent activities per workflow), it stops dispatching new runnables until slots free up. Runic's `plan_eagerly/1` identifies all ready runnables, but the worker gates dispatch.

**Node level:** the `DynamicSupervisor` enforces `max_children`. New workflow activations beyond this limit return `{:error, :overloaded}` to the control plane, which routes to another node. The `Task.Supervisor` partition count bounds total concurrent activity tasks per node.

**System level:** the Postgres activity queue provides natural backpressure — if workers can't keep up, tasks accumulate. A queue depth metric triggers alerts. In Fizz, rate limiting and quotas should key off `workos_organization_id` and `project_id`, not a synthetic tenant id, so one noisy project cannot monopolize shared capacity inside an organization.

```elixir
# In Fizz.Workflows.RunWorker
defp maybe_dispatch(%{in_flight: in_flight, max_concurrency: max} = state)
     when map_size(in_flight) >= max do
  state  # backpressure: wait for completions
end

defp maybe_dispatch(state) do
  runnables = Workflow.plan_eagerly(state.workflow)
  slots = state.max_concurrency - map_size(state.in_flight)
  {to_dispatch, _rest} = Enum.split(runnables, slots)

  Enum.reduce(to_dispatch, state, &dispatch_runnable/2)
end
```

---

## 9. Durable Timers

When a workflow calls `sleep(duration)` or `schedule_at(datetime)`:

1. `Fizz.Workflows.RunWorker` appends a `TimerStarted` event to the SQLite event log.
2. A corresponding row is written to the SQLite `timers` table and the Postgres `durable_timers` table (denormalized for global polling).
3. `Fizz.Workflows.RunWorker` snapshots, passivates (if the timer is far in the future), and stops.

`Fizz.Workflows.TimerPoller` runs a periodic scan (every 1 s for near-term timers, every 60 s for far-future) using `SKIP LOCKED` to avoid contention:

```elixir
def poll_due_timers do
  Repo.query!("""
    UPDATE durable_timers
    SET status = 'FIRING'
    WHERE timer_id IN (
      SELECT timer_id FROM durable_timers
      WHERE fire_at <= now() AND status = 'PENDING'
      ORDER BY fire_at LIMIT 100
      FOR UPDATE SKIP LOCKED
    )
    RETURNING run_id, timer_id, payload
  """)
  |> Enum.each(&wake_workflow/1)
end
```

The wake-up process: claim the lease, download SQLite from S3 if passivated, replay from the latest snapshot, deliver the `TimerFired` event, and resume execution. Total cold-start latency for a typical 1–10 MB SQLite file: 200 ms – 2 s.

For timers firing in the near future (< 5 min), a pre-warming optimization downloads the SQLite file ahead of time so the wake path only needs replay, not download.

---

## 10. Signal Delivery and Deduplication

External signals flow through the Postgres `signal_inbox`, which accepts writes even when the target workflow is passivated in S3:

```elixir
def send_signal(run_id, signal_name, payload, signal_id) do
  # Postgres PRIMARY KEY on signal_id rejects duplicates at the DB level
  Repo.insert!(%Fizz.Workflows.SignalInbox{
    signal_id: signal_id,
    run_id: run_id,
    signal_name: signal_name,
    payload: payload
  })

  # Notify the owning node (latency optimization, not durability mechanism)
  Repo.query!("SELECT pg_notify('signals', $1)", [run_id])
end
```

`Fizz.Workflows.SignalRouter` subscribes to `LISTEN signals` for low-latency delivery. When a notification arrives, it checks if the target workflow is active on this node (via `Registry`); if so, it sends the signal directly. If the workflow is passivated, it enqueues a wake-up. LISTEN/NOTIFY is a latency optimization only — `Fizz.Workflows.SignalRouter` also polls `signal_inbox` periodically to catch any missed notifications.

Inside `Fizz.Workflows.RunWorker`, signal processing uses two layers of dedup:

```elixir
def deliver_signals(db, workflow, fence_token) do
  pending = Repo.all(from s in Fizz.Workflows.SignalInbox,
    where: s.run_id == ^run_id and s.delivered == false,
    order_by: s.received_at)

  Enum.reduce(pending, workflow, fn signal, wf ->
    # Second dedup layer: check per-workflow SQLite
    case query(db, "SELECT 1 FROM processed_signals WHERE signal_id = ?1",
               [signal.signal_id]) do
      [] ->
        Exqlite.transaction(db, fn ->
          # Append SignalReceived event + mark processed atomically
          append_event(db, fence_token, %SignalReceived{signal: signal})
          execute(db, "INSERT INTO processed_signals VALUES (?1, ?2)",
                  [signal.signal_id, now_us()])
        end)
        Workflow.react(wf, {:signal, signal.signal_name, signal.payload})

      _ ->
        wf  # already processed, skip
    end
  end)
end
```

True exactly-once delivery is impossible (Two Generals Problem), but at-least-once delivery combined with idempotent processing produces effectively-exactly-once semantics.

---

## 11. Organization and Project Isolation

### 11.1 Data Isolation

Isolation is enforced at every layer using Fizz's existing org/project model:

**Postgres:** all control-plane tables include `workos_organization_id` and `project_id`. Use `project_id` as the main lookup / authorization key, with `workos_organization_id` denormalized for reporting, quotas, and coarse filtering. RLS can be layered on later if the workflow surface grows beyond server-rendered LiveViews and internal contexts.

**SQLite:** each project's workflow files live in an isolated directory subtree (`{data_dir}/{workos_organization_id}/{project_id}/...`). File-system permissions provide a second isolation boundary. S3 objects are keyed by `s3://{bucket}/{workos_organization_id}/{project_id}/{run_id}.sqlite`.

**Phoenix / LiveView:** reuse the existing authenticated browser stack, `@current_scope`, and project-scope resolution. LiveViews should sit in the existing `scope "/", FizzWeb` with `pipe_through [:browser, :require_authenticated_user]` and `live_session :require_authenticated_user`; any controller/API entrypoints should resolve project scope the same way `FizzWeb.Plugs.RequireProjectScope` already does.

### 11.2 Resource Quotas

```elixir
defmodule Fizz.Workflows.Quotas do
  @defaults %{
    max_active_runs:    1_000,
    max_run_history_mb: 50,
    max_events_per_run: 50_000,
    max_signal_rate:    100,     # per second
    max_activity_concurrency: 50
  }

  def check_quota!(project_id, :start_run) do
    active = Repo.count(Fizz.Workflows.WorkflowRun, project_id: project_id, status: "RUNNING")
    limit = get_limit(project_id, :max_active_runs)
    if active >= limit, do: raise QuotaExceededError
  end
end
```

Quotas are stored in Postgres and cached in ETS with a short TTL. In Fizz, start with project-level limits and optionally layer organization-wide caps above them. Per-organization and per-project metrics (active runs, total storage, activity throughput) feed into billing and alerting.

---

## 12. State Versioning and Code Evolution

### 12.1 Workflow Definition Versioning

Long-lived workflows must survive code deploys. Runic's model is primarily state reconstruction from an event log rather than deterministic replay of workflow code, which is an advantage — `Workflow.from_log/1` rebuilds the graph from serialized events rather than re-executing past steps. However, for pending runnables that will execute in the future (months or years later), code evolution matters.

Runic stores components using serializable closures that include the quoted AST source and captured bindings. This helps portability but does not guarantee semantic stability if a step references external module functions whose behavior changes. The versioning strategy:

```elixir
# Postgres stores the definition revision for each run
ALTER TABLE workflow_runs ADD COLUMN definition_version INTEGER NOT NULL DEFAULT 1;

# Fizz.Workflows.RunWorker checks compatibility on wake
def activate(run_id) do
  run = Repo.get!(Fizz.Workflows.WorkflowRun, run_id)
  current_version = Fizz.Workflows.Definitions.current_version(run.workflow_type)

  cond do
    run.definition_version == current_version ->
      :ok  # compatible, proceed

    run.definition_version in Fizz.Workflows.Definitions.compatible_versions(run.workflow_type) ->
      :ok  # explicitly marked compatible

    true ->
      {:error, :incompatible_version,
       "run uses definition v#{run.definition_version}, current is v#{current_version}"}
  end
end
```

### 12.2 SQLite Schema Migration on Wake

Long-dormant SQLite databases transparently upgrade their schema when loaded, using `PRAGMA user_version`:

```elixir
@migrations [
  {1, &Migration.V1.create_base_tables/1},
  {2, &Migration.V2.add_outbox_table/1},
  {3, &Migration.V3.add_snapshot_version_column/1}
]

def open_and_migrate(path) do
  {:ok, db} = Exqlite.open(path)
  [{current}] = query(db, "PRAGMA user_version")

  for {version, migrate_fn} <- @migrations, current < version do
    Exqlite.transaction(db, fn ->
      migrate_fn.(db)
      execute(db, "PRAGMA user_version = #{version}")
    end)
  end

  db
end
```

Migrations must be idempotent (`CREATE TABLE IF NOT EXISTS`, `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`), forward-only, and atomic. If the database version is *higher* than the code knows, the engine refuses to open it — preventing data corruption from running old code against a newer schema.

---

## 13. Observability

### 13.1 Metrics (Prometheus / OpenTelemetry)

```elixir
# :telemetry events emitted by the platform
:telemetry.execute([:fizz, :workflows, :step], %{duration: elapsed}, %{
  workos_organization_id: workos_organization_id,
  project_id: project_id,
  workflow_type: type,
  step: step_name,
  status: :ok | :error
})

# Key metrics to export
- fizz.workflows.step.duration        (histogram, by org + project + type)
- fizz.workflows.active.count         (gauge, by node + org + project)
- fizz.workflows.cold_start.duration  (histogram)
- fizz.workflows.activity.duration    (histogram, by activity_type)
- fizz.workflows.activity.queue.depth (gauge, by activity_type)
- fizz.workflows.timer.fire.lag       (histogram — fire_at vs actual)
- fizz.workflows.sqlite.file_size     (histogram)
- fizz.workflows.sqlite.event_count   (histogram)
- fizz.workflows.passivation.count    (counter)
- fizz.workflows.lease.renewal.error  (counter — critical alert)
```

### 13.2 Distributed Tracing

Every workflow run carries a `trace_id` (generated at creation or extracted from the initiating request). The trace ID propagates through event payloads, creating spans for workflow execution, each activity invocation, signal processing, and timer fires:

```elixir
def dispatch_activity(runnable, ctx) do
  span_ctx = OpenTelemetry.Tracer.start_span("activity.#{runnable.type}", %{
    attributes: %{
      "workflow.run_id" => ctx.run_id,
      "workflow.organization_id" => ctx.workos_organization_id,
      "workflow.project_id" => ctx.project_id,
      "activity.runnable_id" => runnable.id
    }
  })
  # propagate span context to the activity task
end
```

### 13.3 Time-Travel Debugging

Per-workflow SQLite databases provide a unique advantage: any workflow's complete state can be inspected offline by downloading its SQLite file from S3 and querying it with standard tools — no running engine required, no risk of side effects. To inspect state at any historical point: load the latest snapshot before the target sequence number, replay events through that point, and examine the reconstructed Runic workflow.

The Phoenix LiveView operator console exposes: describe (metadata, pending activities/timers, search attributes), list/count with SQL-like filtering across the Postgres global index, get history (full event log from the per-workflow SQLite), signal/query/update (interact with live or dormant workflows), reset (rewind to a specific event and re-execute for bug recovery), and terminate/cancel. In this repo that should be implemented as project-scoped LiveViews alongside the existing `ProjectsLive` / `WorkspacesLive` screens, not as a separate unaffiliated admin surface.

Litestream WAL segment retention in S3 enables point-in-time recovery to any moment within the retention window, analogous to Cloudflare Durable Objects' 30-day point-in-time recovery.

---

## 14. Security

### 14.1 Authentication and Authorization

The first workflow UI/API surface should reuse the auth and routing model already in the repo. LiveViews belong in the existing authenticated browser scope and `live_session :require_authenticated_user`, because that is where `@current_scope` is assigned. Project-scoped controllers or channels should resolve a project-aware scope the same way `FizzWeb.Plugs.RequireProjectScope` does today. A service-to-service JWT/API-key entrypoint can be added later if needed, but it should still resolve to the same organization/project authorization model rather than inventing a parallel tenancy scheme.

| Operation | project member / viewer | project admin | organization admin / owner |
|-----------|--------------------------|---------------|-----------------------------|
| Query / inspect | yes | yes | yes |
| Start / signal | member only | yes | yes |
| Cancel / terminate | no | yes | yes |
| Reset / rewind | no | yes | yes |
| Manage org/project quotas | no | no | yes |
| Cross-project access in same org | no | no | yes |

### 14.2 Data Protection

**Encryption at rest:** S3 server-side encryption (SSE-S3 or SSE-KMS) for passivated SQLite files. Node-local SQLite files reside on encrypted volumes (dm-crypt / LUKS or cloud provider disk encryption). Postgres uses TDE or encrypted storage.

**Encryption in transit:** TLS for all Postgres connections, S3 API calls, and inter-node communication. The Phoenix endpoint enforces HTTPS.

**Payload encryption:** for sensitive workflow data (PII, payment info), activity inputs/outputs are encrypted at the application layer with per-organization KEKs before writing to SQLite or Postgres. The encryption key hierarchy: organization KEK (in KMS) → per-run DEK (stored encrypted in workflow metadata).

**Secrets management:** activity credentials (API keys, OAuth tokens) are never stored in workflow state. Activities fetch secrets from Vault or AWS Secrets Manager at execution time, referenced by name only.

### 14.3 Audit Trail

The append-only SQLite event log is a natural audit trail. For compliance-critical workflows, the outbox pattern publishes events to an immutable audit log (S3 + Athena, or a dedicated Postgres audit table). Operator actions (reset, cancel, signal) are logged with the acting principal, timestamp, and justification.

---

## 15. Failure Modes and Mitigations

| Failure | Impact | Mitigation |
|---------|--------|------------|
| **Worker process crash** | In-memory Runic state lost | DynamicSupervisor restarts worker; `from_log/1` restores from SQLite snapshot + events; `pending_runnables/1` identifies in-flight work for re-dispatch |
| **Node failure** | All workflows on node orphaned | Leases expire (30 s TTL); other nodes claim orphaned workflows; Litestream's S3 replica provides the latest SQLite state (sub-second RPO) |
| **Split-brain / stale owner** | Two nodes believe they own the same workflow | Fencing tokens are the ultimate safety net. The stale writer's SQLite transaction fails the fence check. Postgres lease with monotonic `fence_token` ensures only the latest owner's writes succeed |
| **Postgres outage** | No new lease claims, no timer polling, no signal routing | Active workflows with valid leases continue executing using local SQLite. New activations and timer fires queue until Postgres recovers. Postgres streaming replication or CockroachDB for HA |
| **S3 outage** | Cannot passivate or wake cold workflows | Active workflows unaffected. Passivation retries with backoff. Wake-from-cold queues until S3 recovers. Warm-tier LRU cache on local SSD reduces S3 dependency |
| **SQLite corruption** | Workflow state unrecoverable from local file | Litestream S3 replica serves as backup. Restore from latest S3 snapshot. Point-in-time recovery from retained WAL segments |
| **Litestream lag** | Potential data loss window if node dies during lag | `synchronous=NORMAL` + WAL means committed data survives process crashes. For the OS-crash window, accept sub-second RPO or upgrade to `synchronous=FULL` (at ~2× write latency cost) |
| **Activity timeout without result** | Workflow stuck waiting | `schedule_to_close_timeout` expires → engine records `ActivityTimedOut` → retry policy decides retry or fail. Heartbeat timeout catches crashed workers faster than the full timeout |
| **Schema incompatibility on wake** | Old SQLite opened by new code, or vice versa | `user_version` check on open. Migration-on-wake upgrades old schemas forward. Code refuses to open databases with a higher version than it knows |

---

## 16. Rollout Plan

### Phase 1: Foundation (Weeks 1–4)

**Goal:** core execution loop running on a single node with Postgres coordination.

- Implement `Fizz.Workflows.RunWorker` GenServer wrapping Runic's three-phase cycle.
- Implement the `Runic.Runner.Store` behaviour backed by SQLite (using Exqlite). Wire up `Workflow.log/1` and `Workflow.from_log/1` for checkpoint/restore.
- Stand up Postgres control-plane tables: `workflow_runs`, `shard_leases`, `activity_tasks`.
- Implement lease acquisition and fence-token validation in SQLite writes.
- Prototype activity dispatch on the existing Oban installation first, and only keep a bespoke `SKIP LOCKED` queue if runnable-level claiming / heartbeats need tighter control than Oban provides.
- Integration tests: start workflow → dispatch activity → record result → crash worker → restore from SQLite → verify state.

### Phase 2: Durability and Timers (Weeks 5–8)

**Goal:** workflows survive node restarts and sleep for arbitrary durations.

- Integrate Litestream for continuous SQLite → S3 replication.
- Implement passivation tiers (hot → warm → cold) with `Fizz.Workflows.PassivationSweeper`.
- Implement `durable_timers` table and `Fizz.Workflows.TimerPoller` with cold-start wake-up path.
- Implement snapshot-on-passivation and snapshot-every-N-events.
- Implement `ContinueAsNew` for workflows exceeding event/size limits.
- Chaos tests: kill nodes mid-execution, verify resume from S3 with correct state.

### Phase 3: Signals, Org/Project Isolation, and API (Weeks 9–12)

**Goal:** external interaction and repo-native isolation.

- Implement `signal_inbox` and `Fizz.Workflows.SignalRouter` with `LISTEN/NOTIFY` optimization.
- Implement two-layer signal deduplication (Postgres + per-workflow SQLite).
- Add `workos_organization_id` + `project_id` to all workflow tables; wire authorization through `%Fizz.Accounts.Scope{}` and `Accounts.build_scope_for_project/2`.
- Build Phoenix workflow routes under the existing authenticated project area first (`/projects/:project_id/workflows/...`), then add external API endpoints only if they are actually needed.
- Implement project/org role checks first; add JWT/API-key authentication only for external entrypoints that genuinely need it.
- Load tests: 10,000 concurrent workflows across many projects / organizations, with simulated signal traffic.

### Phase 4: Operator Tooling and Observability (Weeks 13–16)

**Goal:** production-grade visibility and control.

- Build Phoenix LiveView operator console (list, search, describe, history viewer, signal, reset).
- Implement OpenTelemetry tracing with trace-ID propagation through events.
- Wire up Prometheus metrics for all key indicators.
- Implement time-travel debugging (download SQLite from S3, replay to arbitrary point).
- Implement schema migration-on-wake with `user_version`.
- Implement workflow definition versioning in Postgres.

### Phase 5: Hardening and Production (Weeks 17–20)

**Goal:** production readiness under failure conditions.

- Comprehensive failure-mode testing: split-brain, Postgres failover, S3 outage, Litestream lag.
- Security audit: payload encryption, secrets management, audit trail.
- Performance profiling: cold-start latency optimization, SQLite file size monitoring, query plan analysis on Postgres indexes.
- Runbook documentation for operational scenarios.
- Canary deployment with shadow traffic, then graduated rollout.

---

## Appendix A: Technology Choices Summary

| Concern | Technology | Rationale |
|---------|-----------|-----------|
| Workflow VM | Runic | Dataflow DAG with lazy eval, three-phase model, event-log restoration, pluggable store, BEAM-native |
| Per-run state | SQLite (WAL mode) | ACID with zero network overhead, single-writer = structural linearizability, sub-ms reads, portable file |
| Durability | Litestream → S3 | Sub-second WAL replication, ~$1/mo storage, no Raft complexity |
| Coordination | Postgres + Oban | Reuse the repo's existing Postgres-backed job substrate where possible; add leases / SKIP LOCKED only where workflow ownership semantics require it |
| API / Operator UI | Phoenix + LiveView | Real-time operator console, gRPC/REST APIs, built-in auth |
| Supervision | OTP | DynamicSupervisor, Registry, Task.Supervisor, PartitionSupervisor — battle-tested primitives |
| Observability | OpenTelemetry + Prometheus | Distributed tracing, metrics, integrates with Grafana/Datadog |
| Secrets | Vault / AWS SM | Runtime secret fetch, never stored in workflow state |

## Appendix B: SQLite File Management

**Directory layout:** `{data_dir}/{workos_organization_id}/{project_id}/{hash[0:2]}/{hash[2:4]}/{run_id}.sqlite`

**File descriptor budget:** each open SQLite in WAL mode consumes ~3 FDs (main DB, WAL, SHM). At 10,000 active workflows per node: ~30,000 FDs. Set `ulimit -n 65536`. Idle workflows should be aggressively closed (tier 1 warm = file closed, metadata in Registry).

**File size targets:** typical workflow 100 KB – 10 MB. Alert at 50 MB. Hard limit via `ContinueAsNew` at 50 MB or 50,000 events.

**WAL checkpoint policy:** Litestream manages checkpointing. Manual checkpoint on passivation via `PRAGMA wal_checkpoint(TRUNCATE)` to minimize upload size.
