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

## 2. Foundational Insight: The Workflow IS the Execution

The deepest architectural insight in this design is that **Runic workflows are self-contained values that carry both their structure and execution state in a single data structure**. A `%Workflow{}` contains the DAG of steps and rules (structure), all produced facts with causal ancestry (execution history), runnable/ran edge markers (progress state), and accumulated state from reducers and state machines — all in one value.

This has profound consequences:

1. **The workflow IS the event store.** `Workflow.log/1` returns the complete serializable history — `ComponentAdded` events for structure, `ReactionOccurred` events for execution state, `RunnableDispatched/Completed/Failed` for durable lifecycle tracking. `Workflow.from_log/1` reconstructs everything. We do not need a separate event-sourcing layer.

2. **Checkpointing is trivial.** Persisting a workflow is `:erlang.term_to_binary(Workflow.log(workflow))`. Restoring is `Workflow.from_log(:erlang.binary_to_term(data))`. No custom replay logic, no sequence numbers, no snapshot/event separation.

3. **Time-travel is a one-liner.** `Workflow.from_log(Enum.take(log, n))` gives you the workflow at any historical point. You can fork a workflow at any point by replaying a prefix and feeding different inputs. You can diff two workflow states by comparing their production graphs.

4. **One SQLite file per execution, not per definition.** A "definition" is just a function that builds a fresh `%Workflow{}`. The moment you feed it input, facts and causal edges enter the graph alongside the structure. Two executions cannot share a workflow value without colliding. Each execution maps 1:1 to a SQLite file.

5. **Runic.Runner already provides the execution infrastructure.** Supervised workers, task dispatch, policy-driven retries/timeouts/fallbacks, configurable checkpointing, crash recovery via `pending_runnables/1`, telemetry — all built in. We extend Runic via its `Runner.Store` behaviour rather than rebuilding worker infrastructure.

This means our platform's responsibility narrows to what Runic *doesn't* provide: **coordination across nodes** (leases, fencing), **durable sleep** (timers in Postgres), **external interaction when dormant** (signal inbox), **storage management** (SQLite + Litestream + S3 passivation), and **multi-tenant isolation** (org/project scoping).

---

## 3. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CONTROL PLANE (Postgres)                     │
│                                                                     │
│  ┌───────────────┐  ┌──────────────┐  ┌────────────┐  ┌───────────┐ │
│  │ Global Index  │  │ Lease Table  │  │ Timer Svc  │  │ Signal    │ │
│  │ (routing,     │  │ (ownership,  │  │ (durable   │  │ Inbox     │ │
│  │  search,      │  │  fencing)    │  │  wakeups)  │  │ (dedup,   │ │
│  │  org/project  │  │              │  │            │  │ delivery) │ │
│  │  scope)       │  │              │  │            │  │           │ │
│  └──────┬────────┘  └──────┬───────┘  └─────┬──────┘  └─────┬─────┘ │
│         │                 │                │              │         │
│         └────────────┬────┴────────────────┴──────────────┘         │
│                      │  LISTEN / NOTIFY                             │
└──────────────────────┼──────────────────────────────────────────────┘
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
   ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
   │ Worker Node │ │ Worker Node │ │ Worker Node │
   │ (Elixir)    │ │ (Elixir)    │ │ (Elixir)    │
   │             │ │             │ │             │
   │ ┌─────────┐ │ │ ┌─────────┐ │ │ ┌─────────┐ │
   │ │ Runic   │ │ │ │ Runic   │ │ │ │ Runic   │ │
   │ │ Runner  │ │ │ │ Runner  │ │ │ │ Runner  │ │
   │ │ Workers │ │ │ │ Workers │ │ │ │ Workers │ │
   │ └────┬────┘ │ │ └────┬────┘ │ │ └────┬────┘ │
   │      │      │ │      │      │ │      │      │
   │ ┌────▼────┐ │ │ ┌────▼────┐ │ │ ┌────▼────┐ │
   │ │ SQLite  │ │ │ │ SQLite  │ │ │ │ SQLite  │ │
   │ │ Store   │ │ │ │ Store   │ │ │ │ Store   │ │
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
   │          Phoenix LiveView Console            │
   │  (list · search · describe · signal · reset) │
   └──────────────────────────────────────────────┘
```

**Three-layer summary.** The *data plane* is Runic Runner workers, each backed by a custom `Runner.Store` adapter that persists `Workflow.log/1` to a node-local SQLite database in WAL mode. Litestream continuously replicates WAL frames to S3 for durability. The *coordination layer* is Postgres-backed leases with fencing tokens, enforcing single-writer ownership per workflow execution. The *control plane* is Postgres tables (global index, timer service, signal inbox) plus a stateless Phoenix frontend and operator console.

The structural insight: Runic's `%Workflow{}` is a self-contained value carrying both structure and execution state. SQLite's single-writer constraint eliminates coordination problems *within* a workflow execution — the entire checkpoint is one atomic write of the serialized workflow log. The coordination challenge reduces to execution-to-owner mapping, solved by leases and fencing tokens in Postgres.

---

## 4. OTP Supervision Tree

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
│   ├── Runic.Runner (name: Fizz.Workflows.Runner)
│   │   ├── Fizz.Workflows.Store.SQLiteLitestream (Store adapter — GenServer)
│   │   ├── Registry (Fizz.Workflows.Runner.Registry)
│   │   ├── Task.Supervisor (or PartitionSupervisor)
│   │   └── DynamicSupervisor (Fizz.Workflows.Runner.WorkerSupervisor)
│   │       └── Runic.Runner.Worker (one per active workflow execution)
│   │           ├── owns: %Runic.Workflow{} (in-memory state)
│   │           ├── delegates to: Store adapter for checkpoint/restore
│   │           └── uses: SchedulerPolicy + PolicyDriver for retries/timeouts
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

The `Fizz.Workflows.ControlPlane.Supervisor` uses `rest_for_one` so that if the `Fizz.Workflows.LeaseManager` crashes, the `Fizz.Workflows.TimerPoller` and `Fizz.Workflows.SignalRouter` also restart — they depend on valid leases.

`Runic.Runner` is used directly rather than building a parallel worker infrastructure. It already provides DynamicSupervisor, Registry, Task.Supervisor (with optional PartitionSupervisor), and Store-backed persistence. Each `Runic.Runner.Worker` wraps a `%Workflow{}`, dispatches runnables via `Task.Supervisor.async_nolink`, executes through `PolicyDriver` with configured retry/timeout/fallback policies, and checkpoints via the Store adapter.

The custom `Fizz.Workflows.Store.SQLiteLitestream` adapter implements `Runic.Runner.Store` behaviour to bridge Runic's persistence abstraction with our SQLite + Litestream + S3 storage layer.

---

## 5. Data Model

### 5.1 Postgres — Control Plane Tables

```sql
-- Workflow execution registry and routing index
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

-- Durable timers (denormalized from per-run state for global polling)
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
```

Suggested Ecto surface for the control plane:

- `Fizz.Workflows.WorkflowRun`
- `Fizz.Workflows.ShardLease`
- `Fizz.Workflows.DurableTimer`
- `Fizz.Workflows.SignalInbox`

Note the absence of an `activity_tasks` table. Runic's Runner dispatches activities locally via `Task.Supervisor.async_nolink` with `PolicyDriver`-managed retries, timeouts, and fallbacks. Since each workflow execution is owned by a single node (enforced by leases), cross-node activity dispatch is unnecessary for v1. If the need arises later, validate whether the existing Oban installation can own the responsibility before introducing a bespoke queue table.

### 5.2 SQLite — Per-Execution Store

Each workflow execution gets its own SQLite file at `{data_dir}/{workos_organization_id}/{project_id}/{prefix1}/{prefix2}/{run_id}.sqlite`. The two-level hash-prefix directory structure keeps directory sizes below ~4,000 entries.

**The SQLite schema is minimal because Runic's `Workflow.log/1` is the canonical persistence format:**

```sql
-- Applied on first open
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA cache_size = -8000;       -- 8 MB page cache
PRAGMA wal_autocheckpoint = 0;   -- Litestream manages checkpointing
PRAGMA user_version = 1;         -- schema version for migration-on-wake

-- The workflow log — the single source of truth
-- Each row is a checkpoint: the complete serialized Workflow.log() output
CREATE TABLE workflow_checkpoints (
    checkpoint_id   INTEGER PRIMARY KEY AUTOINCREMENT,
    log_data        BLOB NOT NULL,        -- :erlang.term_to_binary(Workflow.log(workflow))
    log_entry_count INTEGER NOT NULL,     -- length(Workflow.log(workflow)), for metrics
    created_at_us   INTEGER NOT NULL      -- System.os_time(:microsecond)
);

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

**Why not a separate events table?** Runic workflows are self-contained event-sourced values. `Workflow.log/1` returns the complete ordered list of `ComponentAdded`, `ReactionOccurred`, `RunnableDispatched`, `RunnableCompleted`, and `RunnableFailed` events. `Workflow.from_log/1` reconstructs the full workflow from this list — structure, execution state, causal history, pending runnables, everything. Building a parallel event store with its own sequence numbers and replay logic would duplicate what Runic already provides and create a second source of truth.

Checkpointing writes the full `Workflow.log()` output. Restoring deserializes the latest checkpoint and calls `Workflow.from_log/1`. For workflows with very large histories, older checkpoints can be pruned since each checkpoint is self-contained.

**Configuration rationale.** Disabling `wal_autocheckpoint` is critical when Litestream manages replication: Litestream holds a read transaction to monitor WAL growth and takes over checkpoint scheduling. `synchronous=NORMAL` gives durability to committed transactions on the WAL (data survives process crash but not OS crash mid-write — Litestream's sub-second S3 replication covers the OS-crash window). WAL mode lets the store adapter write checkpoints while concurrent readers (operator queries, metrics collection) access consistent snapshots without blocking.

---

## 6. The Store Adapter: Bridging Runic and Infrastructure

The highest-leverage implementation in this design is the custom `Runic.Runner.Store` adapter. This is where Runic's execution infrastructure meets our durability and coordination layers.

### 6.1 Store Implementation

```elixir
defmodule Fizz.Workflows.Store.SQLiteLitestream do
  @behaviour Runic.Runner.Store

  @moduledoc """
  Runic Runner Store adapter backed by SQLite + Litestream + S3.

  Each workflow execution gets its own SQLite file. Litestream continuously
  replicates WAL frames to S3. On passivation, the file is uploaded to S3
  and the local copy may be evicted.

  This adapter handles:
  - SQLite file lifecycle (create, open, close, migrate)
  - Fence token validation on every write
  - Litestream child process management
  - Passivation/restoration to/from S3
  - Checkpoint writes as atomic SQLite transactions
  """

  use GenServer

  # --- Store Behaviour ---

  @impl Runic.Runner.Store
  def init_store(opts) do
    runner_name = Keyword.fetch!(opts, :runner_name)
    data_dir = Keyword.fetch!(opts, :data_dir)
    s3_bucket = Keyword.fetch!(opts, :s3_bucket)
    {:ok, %{runner_name: runner_name, data_dir: data_dir, s3_bucket: s3_bucket}}
  end

  @impl Runic.Runner.Store
  def save(workflow_id, log, state) do
    with {:ok, db} <- ensure_open(workflow_id, state),
         :ok <- validate_fence(db, workflow_id, state),
         :ok <- write_checkpoint(db, log) do
      :ok
    end
  end

  @impl Runic.Runner.Store
  def load(workflow_id, state) do
    with {:ok, db} <- ensure_open(workflow_id, state),
         {:ok, log_data} <- read_latest_checkpoint(db) do
      {:ok, :erlang.binary_to_term(log_data)}
    else
      {:error, :no_checkpoint} ->
        # Try S3 restoration for passivated workflows
        restore_from_s3(workflow_id, state)
      error ->
        error
    end
  end

  @impl Runic.Runner.Store
  def checkpoint(workflow_id, log, state) do
    save(workflow_id, log, state)
  end

  @impl Runic.Runner.Store
  def delete(workflow_id, state) do
    close_and_remove(workflow_id, state)
  end

  @impl Runic.Runner.Store
  def list(state) do
    # Query Postgres workflow_runs for active runs on this node
    {:ok, Fizz.Workflows.list_active_run_ids(state.runner_name)}
  end

  @impl Runic.Runner.Store
  def exists?(workflow_id, state) do
    file_exists?(workflow_id, state) or s3_exists?(workflow_id, state)
  end

  # --- Internal: SQLite Operations ---

  defp write_checkpoint(db, log) do
    serialized = :erlang.term_to_binary(log, [:compressed])

    Exqlite.transaction(db, fn ->
      Exqlite.execute(db, """
        INSERT INTO workflow_checkpoints (log_data, log_entry_count, created_at_us)
        VALUES (?1, ?2, ?3)
      """, [serialized, length(log), System.os_time(:microsecond)])

      # Prune old checkpoints, keeping only the latest 3
      Exqlite.execute(db, """
        DELETE FROM workflow_checkpoints
        WHERE checkpoint_id NOT IN (
          SELECT checkpoint_id FROM workflow_checkpoints
          ORDER BY checkpoint_id DESC LIMIT 3
        )
      """)
    end)
  end

  defp read_latest_checkpoint(db) do
    case Exqlite.query(db,
      "SELECT log_data FROM workflow_checkpoints ORDER BY checkpoint_id DESC LIMIT 1"
    ) do
      [{log_data}] -> {:ok, log_data}
      [] -> {:error, :no_checkpoint}
    end
  end

  # ... fence validation, S3 operations, Litestream management ...
end
```

### 6.2 Wiring into the Runner

```elixir
# In application supervision tree
{Runic.Runner,
  name: Fizz.Workflows.Runner,
  store: Fizz.Workflows.Store.SQLiteLitestream,
  store_opts: [
    data_dir: Application.get_env(:fizz, :workflow_data_dir),
    s3_bucket: Application.get_env(:fizz, :workflow_s3_bucket)
  ],
  task_supervisor: {:partition, System.schedulers_online()}}
```

### 6.3 Starting and Running Workflows

```elixir
defmodule Fizz.Workflows do
  @moduledoc """
  Public API for workflow operations. Wraps Runic.Runner with
  Postgres coordination (leases, timers, signals) and org/project scoping.
  """

  def start_workflow(project_id, workflow_type, input, opts \\ []) do
    run_id = Uniq.UUID.uuid7()
    workflow = build_workflow(workflow_type)

    # 1. Register in Postgres
    {:ok, _run} = create_workflow_run(run_id, project_id, workflow_type, opts)

    # 2. Acquire lease
    {:ok, fence_token} = Fizz.Workflows.LeaseManager.acquire(run_id)

    # 3. Start Runic Runner worker with scheduler policies
    workflow = attach_policies(workflow, workflow_type)

    {:ok, _pid} = Runic.Runner.start_workflow(
      Fizz.Workflows.Runner,
      run_id,
      workflow,
      max_concurrency: opts[:max_concurrency] || 10,
      checkpoint_strategy: :every_cycle,
      on_complete: {Fizz.Workflows, :on_workflow_complete, [run_id]}
    )

    # 4. Feed initial input
    :ok = Runic.Runner.run(Fizz.Workflows.Runner, run_id, input)

    {:ok, run_id}
  end

  def get_results(run_id) do
    Runic.Runner.get_results(Fizz.Workflows.Runner, run_id)
  end

  def get_workflow(run_id) do
    Runic.Runner.get_workflow(Fizz.Workflows.Runner, run_id)
  end

  defp attach_policies(workflow, workflow_type) do
    policies = Fizz.Workflows.Definitions.policies_for(workflow_type)

    Enum.reduce(policies, workflow, fn {matcher, policy}, wf ->
      Workflow.add_scheduler_policy(wf, matcher, policy)
    end)
  end
end
```

---

## 7. Execution Semantics

### 7.1 Runic as the Execution Kernel

Runic serves as the workflow virtual machine. Its dataflow DAG with lazy evaluation and concurrency models "programs as data-driven workflows," supporting runtime composition. The three-phase model is the critical enabler:

1. **Prepare**: `Workflow.prepare_for_dispatch/1` walks the DAG and extracts nodes whose input facts are satisfied into `%Runnable{}` structs containing everything needed for isolated execution.
2. **Execute**: Runnables dispatch to `Task.Supervisor.async_nolink` via the Runner. Each runnable carries a stable `id` derived from `{node.hash, fact.hash}`, which serves as a natural idempotency key. `PolicyDriver` wraps execution with configurable retries, timeouts, backoff, and fallbacks.
3. **Apply**: Task results return via `{ref, result}` messages. The Runner Worker applies completed runnables back to the workflow via `Workflow.apply_runnable/2`, then checkpoints via the Store adapter.

**This entire cycle is already implemented in `Runic.Runner.Worker`.** The Worker handles the dispatch loop (plan → prepare → dispatch → apply), tracks active tasks, manages backpressure via `max_concurrency`, and calls `Store.checkpoint/3` according to the configured strategy.

### 7.2 The Step Lifecycle

```
                      ┌──────────────────────────────────────┐
                      │ Runic.Runner.Worker (per execution)   │
                      │                                       │
  signal/timer ──────►│  1. Workflow.plan_eagerly(wf, input)  │
                      │  2. Workflow.prepare_for_dispatch(wf) │
                      │  3. For each runnable:                │
                      │     a. SchedulerPolicy.resolve(...)   │
                      │     b. Task.Supervisor.async_nolink   │
                      │        └─ PolicyDriver.execute(...)   │
                      │           (retries, timeout, fallback)│
                      │  4. On task completion (handle_info): │
                      │     a. Workflow.apply_runnable(wf, r) │
                      │     b. Store.checkpoint(id, log)      │
                      │        └─ SQLite atomic write         │
                      │           (fence check + log blob)    │
                      │     c. plan_eagerly → loop to 2       │
                      │  5. When !is_runnable?(wf):           │
                      │     a. Store.save(id, log)            │
                      │     b. on_complete callback           │
                      └──────────────────────────────────────┘
```

### 7.3 Idempotency and Exactly-Once Semantics

The system enforces a clear contract: **workflow state transitions are exactly-once with respect to the workflow log; external side effects are at-least-once and must be made idempotent.**

*Within the workflow boundary*, exactly-once progression is guaranteed because the `%Workflow{}` is a functional value. `Workflow.apply_runnable/2` returns a new workflow with the runnable's effects applied. The fence-checked checkpoint write to SQLite is the durability boundary — if the process crashes before the checkpoint COMMIT, the transaction rolls back atomically and `pending_runnables/1` on the restored workflow identifies work that needs re-dispatch.

*At the activity boundary* (external services), idempotency keys close the loop:

```elixir
defmodule Fizz.Workflows.Activities.ChargePayment do
  def execute(input) do
    # Runic's stable runnable ID ({node.hash, fact.hash}) serves as
    # the natural idempotency key for external calls
    idempotency_key = "#{input.run_id}-#{input.runnable_id}"

    PaymentGateway.charge(
      amount: input.amount,
      currency: input.currency,
      idempotency_key: idempotency_key
    )
  end
end
```

### 7.4 Retry Policy

Retry configuration uses Runic's `SchedulerPolicy`, applied per activity type via matchers:

```elixir
defmodule Fizz.Workflows.Definitions do
  def policies_for(:order_fulfillment) do
    [
      # External API calls: retries with exponential backoff
      {:check_inventory, %{
        max_retries: 3,
        backoff: :exponential,
        base_delay_ms: 1_000,
        timeout_ms: 10_000,
        execution_mode: :durable
      }},
      # Fraud check: skip on failure, don't block the order
      {:screen_fraud, %{
        max_retries: 2,
        backoff: :linear,
        timeout_ms: 15_000,
        on_failure: :skip,
        execution_mode: :durable
      }},
      # Local computation: fast fail
      {:default, %{
        max_retries: 0,
        timeout_ms: 5_000
      }}
    ]
  end
end
```

The `:durable` execution mode enables `RunnableDispatched/Completed/Failed` event emission, which are included in `Workflow.log/1` and survive checkpoint/restore for crash recovery.

---

## 8. State Persistence Strategy

### 8.1 Workflow Log as the Source of Truth

The per-execution SQLite database stores checkpoints of `Workflow.log/1` output. This is a complete, ordered list of events that reconstructs the full workflow:

**Checkpoint (save):**
```elixir
log = Workflow.log(workflow)
serialized = :erlang.term_to_binary(log, [:compressed])
# → atomic SQLite write with fence validation
```

**Restore (load):**
```elixir
log = :erlang.binary_to_term(serialized_data)
workflow = Workflow.from_log(log)
# → full workflow with structure, facts, causal history, pending runnables
```

For a workflow restored after passivation, this is all that's needed — `Workflow.from_log/1` reconstructs the complete state. `pending_runnables/1` identifies any in-flight work for re-dispatch.

**Checkpoint frequency:** Controlled by Runic Runner's `checkpoint_strategy` option:
- `:every_cycle` — checkpoint after each react cycle (maximum durability, default)
- `{:every_n, n}` — checkpoint every N completed runnables (tunable)
- `:on_complete` — checkpoint only when workflow satisfies (fast, risk of losing in-progress work)
- `:manual` — explicit `Runic.Runner.checkpoint/2` calls only

**Log growth management:** Workflows that accumulate beyond 50,000 log entries or 50 MB serialized should use a `ContinueAsNew` pattern — carry forward essential state into a fresh execution with a clean history, preserving the parent execution's SQLite file as an archived artifact.

### 8.2 Passivation Tiers

```
Tier 0: HOT     — Runner.Worker alive, SQLite open on local SSD
                   (active execution, < 50 ms step latency)

Tier 1: WARM    — Runner.Worker stopped, SQLite file on local SSD
                   (LRU cache, re-open in < 10 ms, zero RAM)

Tier 2: COLD    — SQLite uploaded to S3, local file evicted
                   (download + restore in 200 ms – 2 s)

Tier 3: ARCHIVE — Execution completed, SQLite in S3 Glacier
                   (operator inspection only, minutes to restore)
```

The `Fizz.Workflows.PassivationSweeper` GenServer runs a periodic scan (every 60 s) of active workflows via the Runner's Registry. Workflows idle longer than the configured threshold (default 10 min) transition through tiers. On passivation to S3: checkpoint via Store, `PRAGMA wal_checkpoint(TRUNCATE)`, upload, update Postgres `workflow_runs.status = 'PASSIVATED'` and `storage_uri`, stop the Runner Worker via `Runic.Runner.stop/3`.

### 8.3 Litestream Replication

Each active SQLite file gets a Litestream replication process (managed as a Port or a sidecar) that continuously streams WAL frames to S3. Replication lag is typically sub-second; storage cost is roughly $1/month per workflow. This provides disaster recovery: if a node dies, the latest WAL frames are in S3. A new owner downloads the replicated database and resumes via `Runic.Runner.resume/3`.

WAL mode is critical here, and SQLite's documentation explicitly warns that WAL mode does not work on network filesystems because the WAL-index uses shared memory. Our architecture avoids this entirely: SQLite files are always node-local. Cross-node failover works by downloading from S3, never by sharing a filesystem.

---

## 9. Ownership, Leasing, and Fencing

### 9.1 Lease Acquisition

When a node needs to own a workflow execution (new run, wake from cold, timer fire), it executes:

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

### 9.2 Fencing Token Validation

Leases alone are insufficient for safety, as Martin Kleppmann demonstrated: a process can pause (GC, page fault, network delay) after acquiring the lease, the lease expires, another process acquires a higher token, and the stale process resumes. The fencing token prevents stale writes.

The Store adapter validates the fence token on every checkpoint write:

```elixir
defp validate_and_write(db, fence_token, log_data) do
  Exqlite.transaction(db, fn ->
    [{current_fence}] = Exqlite.query(db,
      "SELECT fence_token FROM shard_fence WHERE id = 1")

    if current_fence > fence_token do
      raise StaleOwnerError, "fence #{fence_token} < #{current_fence}"
    end

    Exqlite.execute(db,
      "UPDATE shard_fence SET fence_token = ?1 WHERE id = 1", [fence_token])

    Exqlite.execute(db, """
      INSERT INTO workflow_checkpoints (log_data, log_entry_count, created_at_us)
      VALUES (?1, ?2, ?3)
    """, [log_data, byte_size(log_data), System.os_time(:microsecond)])
  end)
end
```

Because SQLite serializes all writes, this check-and-write is inherently linearizable within a single database file. No external distributed lock is needed at the storage layer.

---

## 10. Backpressure

Backpressure operates at three levels:

**Worker level:** Each `Runic.Runner.Worker` is configured with `max_concurrency`. The Worker tracks in-flight tasks and only dispatches new runnables when slots are available. Runic's `prepare_for_dispatch/1` identifies all ready runnables, but the Worker gates dispatch.

**Node level:** The Runner's `DynamicSupervisor` enforces `max_children`. New workflow activations beyond this limit return `{:error, :max_children}` to the control plane, which routes to another node. The PartitionSupervisor wrapping Task.Supervisor spreads activity tasks across schedulers.

**System level:** Rate limiting and quotas key off `workos_organization_id` and `project_id`, not a synthetic tenant id, so one noisy project cannot monopolize shared capacity inside an organization.

---

## 11. Durable Timers

When a workflow calls `sleep(duration)` or `schedule_at(datetime)`:

1. The workflow step produces a timer fact. The Runner Worker checkpoints.
2. The control plane writes a corresponding row to Postgres `durable_timers`.
3. The Runner Worker passivates (if the timer is far in the future) via `Runic.Runner.stop/3`.

`Fizz.Workflows.TimerPoller` runs a periodic scan (every 1 s for near-term, every 60 s for far-future) using `SKIP LOCKED`:

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

The wake-up process: acquire the lease, `Runic.Runner.resume/3` (which calls `Store.load/2` → downloads from S3 if passivated → `Workflow.from_log/1` → starts a new Worker), deliver the `TimerFired` event as input, and resume execution. Total cold-start latency for a typical 1–10 MB SQLite file: 200 ms – 2 s.

For timers firing in the near future (< 5 min), a pre-warming optimization downloads the SQLite file ahead of time.

---

## 12. Signal Delivery

External signals flow through the Postgres `signal_inbox`, which accepts writes even when the target workflow is passivated in S3:

```elixir
def send_signal(run_id, signal_name, payload, signal_id) do
  Repo.insert!(%Fizz.Workflows.SignalInbox{
    signal_id: signal_id,
    run_id: run_id,
    signal_name: signal_name,
    payload: payload
  })
  Repo.query!("SELECT pg_notify('signals', $1)", [run_id])
end
```

`Fizz.Workflows.SignalRouter` subscribes to `LISTEN signals` for low-latency delivery. When a notification arrives, it checks if the target is active (via Runner Registry); if so, delivers the signal directly via `Runic.Runner.run/4`. If passivated, it enqueues a wake-up.

**Signal dedup leverages the workflow graph itself.** When a signal is delivered as input via `Workflow.react(workflow, signal_fact)`, the fact enters the graph with a content-based hash. On restore, if the same signal content already exists as a processed fact in the graph (with `:ran` edges on its downstream nodes), we know it was already handled. The Postgres `signal_inbox.delivered` flag provides the first layer of dedup; the workflow's own state provides the second without needing a separate SQLite dedup table.

LISTEN/NOTIFY is a latency optimization only — `Fizz.Workflows.SignalRouter` also polls `signal_inbox` periodically to catch any missed notifications.

---

## 13. Organization and Project Isolation

### 13.1 Data Isolation

Isolation is enforced at every layer using Fizz's existing org/project model:

**Postgres:** All control-plane tables include `workos_organization_id` and `project_id`. Use `project_id` as the main lookup / authorization key, with `workos_organization_id` denormalized for reporting, quotas, and coarse filtering.

**SQLite:** Each project's workflow files live in an isolated directory subtree (`{data_dir}/{workos_organization_id}/{project_id}/...`). File-system permissions provide a second isolation boundary. S3 objects are keyed by `s3://{bucket}/{workos_organization_id}/{project_id}/{run_id}.sqlite`.

**Phoenix / LiveView:** Reuse the existing authenticated browser stack, `@current_scope`, and project-scope resolution.

### 13.2 Resource Quotas

```elixir
defmodule Fizz.Workflows.Quotas do
  @defaults %{
    max_active_runs:    1_000,
    max_run_history_mb: 50,
    max_log_entries_per_run: 50_000,
    max_signal_rate:    100,     # per second
    max_activity_concurrency: 50
  }

  def check_quota!(project_id, :start_run) do
    active = Repo.count(Fizz.Workflows.WorkflowRun,
      project_id: project_id, status: "RUNNING")
    limit = get_limit(project_id, :max_active_runs)
    if active >= limit, do: raise QuotaExceededError
  end
end
```

---

## 14. Observability

### 14.1 Metrics (Prometheus / OpenTelemetry)

Runic Runner already emits telemetry events under `[:runic, :runner, ...]`. We extend with platform-specific metrics:

```elixir
# Runic Runner built-in events (automatic):
# [:runic, :runner, :workflow, :start/:stop/:exception]
# [:runic, :runner, :runnable, :start/:stop/:exception]
# [:runic, :runner, :store, :start/:stop/:exception]

# Platform-specific metrics to add:
- fizz.workflows.active.count         (gauge, by node + org + project)
- fizz.workflows.cold_start.duration  (histogram)
- fizz.workflows.timer.fire.lag       (histogram — fire_at vs actual)
- fizz.workflows.sqlite.file_size     (histogram)
- fizz.workflows.sqlite.log_entries   (histogram)
- fizz.workflows.passivation.count    (counter)
- fizz.workflows.lease.renewal.error  (counter — critical alert)
- fizz.workflows.signal.delivery.lag  (histogram)
```

### 14.2 Distributed Tracing

Every workflow execution carries a `trace_id` (generated at creation or extracted from the initiating request). The trace ID propagates through the Runner's telemetry metadata.

### 14.3 Time-Travel Debugging

This is where the workflow-as-value model provides unique capabilities. Because `Workflow.log/1` returns an ordered list of events, and `Workflow.from_log/1` reconstructs the workflow from any prefix, time-travel debugging is trivial:

```elixir
defmodule Fizz.Workflows.TimeTravel do
  @doc """
  Reconstruct a workflow at any historical point.
  """
  def at_point(run_id, event_index) do
    {:ok, log} = load_full_log(run_id)
    Workflow.from_log(Enum.take(log, event_index))
  end

  @doc """
  Fork a workflow at a historical point and feed different input.
  """
  def fork_at(run_id, event_index, new_input) do
    workflow = at_point(run_id, event_index)
    Workflow.react_until_satisfied(workflow, new_input)
  end

  @doc """
  Get the full event timeline for operator display.
  """
  def timeline(run_id) do
    {:ok, log} = load_full_log(run_id)
    Enum.with_index(log, fn event, idx ->
      %{index: idx, type: event.__struct__, summary: summarize(event)}
    end)
  end
end
```

The Phoenix LiveView operator console can expose a slider over the log length, reconstructing the workflow at each point and rendering the Mermaid diagram via `Workflow.to_mermaid/1`. This enables visual debugging of exactly how the workflow evolved — which facts were produced, which conditions matched, which branches were taken — at any historical moment. No special infrastructure needed; it's a direct consequence of the workflow-as-value model.

The operator console exposes: describe (metadata, pending activities/timers), list/count with filtering across the Postgres global index, timeline (full event log with scrubbing), signal/query (interact with live or dormant workflows), fork (replay with different inputs for bug investigation), and terminate/cancel. In this repo that should be implemented as project-scoped LiveViews alongside the existing `ProjectsLive` / `WorkspacesLive` screens.

---

## 15. State Versioning and Code Evolution

### 15.1 Workflow Definition Versioning

Long-lived workflows must survive code deploys. Runic's model is primarily state reconstruction from an event log rather than deterministic replay of workflow code — `Workflow.from_log/1` rebuilds the graph from serialized events rather than re-executing past steps. Runic stores components using serializable closures that include the quoted AST source and captured bindings.

```elixir
# Postgres stores the definition revision for each execution
ALTER TABLE workflow_runs ADD COLUMN definition_version INTEGER NOT NULL DEFAULT 1;

# Version compatibility check on wake
def activate(run_id) do
  run = Repo.get!(Fizz.Workflows.WorkflowRun, run_id)
  current_version = Fizz.Workflows.Definitions.current_version(run.workflow_type)

  cond do
    run.definition_version == current_version -> :ok
    run.definition_version in compatible_versions(run.workflow_type) -> :ok
    true -> {:error, :incompatible_version}
  end
end
```

### 15.2 SQLite Schema Migration on Wake

Long-dormant SQLite databases transparently upgrade their schema when loaded, using `PRAGMA user_version`:

```elixir
@migrations [
  {1, &Migration.V1.create_base_tables/1},
  {2, &Migration.V2.add_outbox_table/1}
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

---

## 16. Security

### 16.1 Authentication and Authorization

The first workflow UI/API surface reuses the auth and routing model already in the repo. LiveViews belong in the existing authenticated browser scope and `live_session :require_authenticated_user`, where `@current_scope` is assigned.

| Operation | project member / viewer | project admin | organization admin / owner |
|-----------|--------------------------|---------------|-----------------------------|
| Query / inspect | yes | yes | yes |
| Start / signal | member only | yes | yes |
| Cancel / terminate | no | yes | yes |
| Fork / time-travel | member only | yes | yes |
| Manage quotas | no | no | yes |

### 16.2 Data Protection

**Encryption at rest:** S3 server-side encryption for passivated SQLite files. Node-local SQLite files on encrypted volumes. Postgres uses TDE or encrypted storage.

**Encryption in transit:** TLS for all Postgres connections, S3 API calls, and inter-node communication.

**Payload encryption:** For sensitive workflow data (PII, payment info), activity inputs/outputs are encrypted at the application layer with per-organization KEKs before entering the workflow as facts.

**Secrets management:** Activity credentials are never stored in workflow state. Activities fetch secrets from Vault or AWS Secrets Manager at execution time, referenced by name only.

### 16.3 Audit Trail

The workflow log (`Workflow.log/1`) is a natural audit trail — it records every structural change, every fact produced, every runnable dispatched/completed/failed. For compliance-critical workflows, the outbox pattern publishes events to an immutable audit log. Operator actions (fork, cancel, signal) are logged with the acting principal, timestamp, and justification.

---

## 17. Failure Modes and Mitigations

| Failure | Impact | Mitigation |
|---------|--------|------------|
| **Worker process crash** | In-memory workflow lost | Runner's DynamicSupervisor restarts Worker; `Store.load/2` restores from latest SQLite checkpoint; `pending_runnables/1` on the restored workflow identifies in-flight work for re-dispatch |
| **Node failure** | All workflows on node orphaned | Leases expire (30 s TTL); other nodes claim orphaned executions; `Runic.Runner.resume/3` loads from S3 via Litestream replica (sub-second RPO) |
| **Split-brain / stale owner** | Two nodes believe they own the same execution | Fencing tokens are the ultimate safety net. The stale writer's SQLite checkpoint fails the fence check. Postgres lease with monotonic `fence_token` ensures only the latest owner's writes succeed |
| **Postgres outage** | No new lease claims, no timer polling, no signal routing | Active workflows with valid leases continue executing using local SQLite. New activations and timer fires queue until Postgres recovers |
| **S3 outage** | Cannot passivate or wake cold workflows | Active workflows unaffected. Passivation retries with backoff. Wake-from-cold queues until S3 recovers. Warm-tier LRU cache on local SSD reduces S3 dependency |
| **SQLite corruption** | Execution state unrecoverable from local file | Litestream S3 replica serves as backup. Point-in-time recovery from retained WAL segments |
| **Litestream lag** | Potential data loss window if node dies during lag | `synchronous=NORMAL` + WAL means committed data survives process crashes. For the OS-crash window, accept sub-second RPO or upgrade to `synchronous=FULL` (at ~2× write latency cost) |
| **Activity timeout** | Workflow stuck waiting | `PolicyDriver` enforces `timeout_ms` per attempt and `schedule_to_close_timeout` for total activity duration. On failure, retry policy decides retry or fail. `on_failure: :skip` allows the workflow to continue past non-critical activities |
| **Schema incompatibility on wake** | Old SQLite opened by new code | `user_version` check on open. Migration-on-wake upgrades old schemas forward. Code refuses to open databases with a higher version than it knows |

---

## 18. Rollout Plan

### Phase 1: Foundation (Weeks 1–4)

**Goal:** Core execution with Runic Runner and SQLite persistence on a single node.

- Implement `Fizz.Workflows.Store.SQLiteLitestream` as a `Runic.Runner.Store` adapter, initially without Litestream (SQLite only).
- Wire `Runic.Runner` into the application supervision tree with the custom store.
- Stand up Postgres control-plane tables: `workflow_runs`, `shard_leases`.
- Implement lease acquisition and fence-token validation in the Store adapter's write path.
- Build `Fizz.Workflows` public API: `start_workflow/4`, `get_results/1`, `get_workflow/1`.
- Define first workflow type with `SchedulerPolicy` configuration.
- Integration tests: start workflow → dispatch activity → checkpoint → crash Worker → Runner restarts → restore from SQLite → verify state via `pending_runnables/1`.

### Phase 2: Durability and Timers (Weeks 5–8)

**Goal:** Workflows survive node restarts and sleep for arbitrary durations.

- Integrate Litestream for continuous SQLite → S3 replication in the Store adapter.
- Implement passivation tiers (hot → warm → cold) with `Fizz.Workflows.PassivationSweeper`.
- Implement `Runic.Runner.resume/3` flow with S3 download path in the Store adapter.
- Implement `durable_timers` table and `Fizz.Workflows.TimerPoller` with cold-start wake-up.
- Implement `ContinueAsNew` for workflows exceeding log entry/size limits.
- Chaos tests: kill nodes mid-execution, verify resume from S3 with correct state.

### Phase 3: Signals, Org/Project Isolation, and API (Weeks 9–12)

**Goal:** External interaction and repo-native isolation.

- Implement `signal_inbox` and `Fizz.Workflows.SignalRouter` with `LISTEN/NOTIFY` optimization.
- Signal dedup: Postgres `signal_id` primary key as first layer; workflow graph fact existence as second layer.
- Add `workos_organization_id` + `project_id` to all workflow tables; wire authorization through `%Fizz.Accounts.Scope{}`.
- Build Phoenix workflow routes under the existing authenticated project area first (`/projects/:project_id/workflows/...`).
- Load tests: 10,000 concurrent workflows across many projects/organizations.

### Phase 4: Operator Tooling and Observability (Weeks 13–16)

**Goal:** Production-grade visibility and control.

- Build Phoenix LiveView operator console (list, search, describe, timeline viewer with log scrubbing).
- Implement time-travel debugging: slider over `Workflow.log/1` length, Mermaid rendering at each point, fork capability.
- Wire up Prometheus metrics for platform-specific indicators (Runner telemetry is automatic).
- Implement OpenTelemetry tracing with trace-ID propagation.
- Implement schema migration-on-wake with `user_version`.
- Implement workflow definition versioning in Postgres.

### Phase 5: Hardening and Production (Weeks 17–20)

**Goal:** Production readiness under failure conditions.

- Comprehensive failure-mode testing: split-brain, Postgres failover, S3 outage, Litestream lag.
- Security audit: payload encryption, secrets management, audit trail.
- Performance profiling: cold-start latency optimization, SQLite file size monitoring.
- Runbook documentation for operational scenarios.
- Canary deployment with shadow traffic, then graduated rollout.

---

## Appendix A: Technology Choices Summary

| Concern | Technology | Rationale |
|---------|-----------|-----------|
| Workflow VM | Runic | Dataflow DAG with lazy eval, three-phase model, event-log restoration, pluggable store, BEAM-native. Workflow-as-value model eliminates need for external event sourcing |
| Execution infrastructure | Runic.Runner | Supervised workers, task dispatch, PolicyDriver retries/timeouts, configurable checkpointing, crash recovery — all built-in |
| Per-execution state | SQLite (WAL mode) | ACID with zero network overhead, single-writer = structural linearizability, portable file. Stores serialized `Workflow.log()` output |
| Durability | Litestream → S3 | Sub-second WAL replication, ~$1/mo storage, no Raft complexity |
| Coordination | Postgres leases + fencing | Single-writer ownership per execution. Reuse repo's existing Postgres; add bespoke leasing only where workflow ownership semantics require it |
| API / Operator UI | Phoenix + LiveView | Real-time operator console with time-travel debugging, auth integration |
| Supervision | OTP via Runic.Runner | DynamicSupervisor, Registry, Task.Supervisor (or PartitionSupervisor) — battle-tested primitives wrapped by Runner |
| Observability | OpenTelemetry + Prometheus | Distributed tracing, metrics. Runner emits telemetry automatically |
| Secrets | Vault / AWS SM | Runtime secret fetch, never stored in workflow state |

## Appendix B: SQLite File Management

**Directory layout:** `{data_dir}/{workos_organization_id}/{project_id}/{hash[0:2]}/{hash[2:4]}/{run_id}.sqlite`

**File descriptor budget:** Each open SQLite in WAL mode consumes ~3 FDs (main DB, WAL, SHM). At 10,000 active workflows per node: ~30,000 FDs. Set `ulimit -n 65536`. Idle workflows should be aggressively closed (tier 1 warm = file closed, metadata in Registry).

**File size targets:** Typical workflow 100 KB – 10 MB. Alert at 50 MB. Hard limit via `ContinueAsNew` at 50 MB or 50,000 log entries.

**WAL checkpoint policy:** Litestream manages checkpointing. Manual checkpoint on passivation via `PRAGMA wal_checkpoint(TRUNCATE)` to minimize upload size.

## Appendix C: Why Per-Execution, Not Per-Definition

A Runic `%Workflow{}` is a value containing both structure and execution state. There is no type-level separation between "definition" and "run" — a definition is just a workflow that hasn't been fed inputs yet. The moment `Workflow.react(workflow, input)` is called, facts and causal edges enter the graph alongside the structure.

Two executions cannot share a workflow value because their facts would collide in the graph, their causal ancestry chains would interleave, and `raw_productions/1` would return mixed results. Each execution maps 1:1 to a SQLite file.

The workflow *template* is just code — a function that builds a fresh `%Workflow{}`:

```elixir
def build_order_workflow do
  Runic.workflow(name: :order_fulfillment, steps: [...])
  |> Workflow.add_scheduler_policy(...)
end
```

This lives in modules, gets compiled, and is shared across all executions. When starting a new execution, call `build_order_workflow()`, get a fresh `%Workflow{}`, and that instance gets its own SQLite file. The lifecycle:

```
Template (code) → fresh %Workflow{} → feed input → checkpoint to SQLite →
  sleep → restore from SQLite → feed more input → complete → archive
```

Long-lived stateful workflows (state machines tracking orders, accumulators aggregating sensor data) are still single executions — the workflow was born, has been fed N inputs, has accumulated state, all in one `%Workflow{}` value, one SQLite file.