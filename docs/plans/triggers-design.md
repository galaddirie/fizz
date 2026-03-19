# Workflow Triggers: Complete System Design

**Elixir · Phoenix · Runic · Oban · Postgres**

---

## 1. Problem and Motivation

The durable workflow platform has an execution kernel (Runic Runner, per-execution SQLite, Postgres control plane) but no mechanism to *start* or *wake* workflow executions from the outside world. Current trigger step executors (`manual_input`, `schedule_trigger`, `on_chat_trigger`) are thin stubs — they define metadata and a passthrough `execute/3`, but the registration, lifecycle, and routing machinery doesn't exist.

This design covers the full trigger surface: basics (manual, webhook, schedule, chat) and advanced patterns (persistent connections, event streams, reactive, presence). The durable execution model — cheap passivation, instant resumability, months-long sleep — unlocks trigger patterns impossible on conventional platforms.

### Fizz Repo Mapping

Triggers are part of the step type system (`lib/fizz/steps/`) and the workflow execution infrastructure (`lib/fizz/workflows/`). The trigger registry and fire routing are new control-plane concerns alongside the existing planned `signal_inbox`, `durable_timers`, and `shard_leases`. Trigger operations are scoped through `%Fizz.Accounts.Scope{}` and `project_id`, matching the rest of the platform.

---

## 2. Foundational Insight: Triggers Are Registered Signal Producers

The deepest architectural insight is that **triggers and signals are the same delivery mechanism with different registration lifecycles**. A trigger is a signal with a persistent, externally-registered source. A signal is a trigger with an ad-hoc, run-scoped source.

This means the system splits into two orthogonal responsibilities:

1. **TriggerRegistry** (new) — manages *what* is listening: webhook URLs, cron schedules, stream consumers, channel topics. Owns the registration lifecycle.
2. **Signal inbox** (existing design, Section 12 of `durable-workflow-system-design.md`) — handles *delivery* once an event arrives. Owns dedup and routing to runs.

When a trigger fires, the routing decision is simple: does the registration target a specific `run_id`? If no → create a new run (definition-level trigger). If yes → deliver a signal to the existing run (run-level trigger / dynamic subscription).

All trigger fires route through Oban (`TriggerFireWorker`) for consistent retry, dedup, and observability.

---

## 3. Trigger Behaviour

The existing `Fizz.Steps.Executors.Behaviour` defines `execute/3` for all step types. Triggers need three additional callbacks that describe their relationship to the outside world.

**Behaviour composition**: Trigger executor modules declare both `@behaviour Fizz.Steps.Executors.Behaviour` (for `execute/3`, `validate_config/1`, `effective_output_schema/1`) and `@behaviour Fizz.Triggers.Behaviour` (for the trigger-specific callbacks below). The `use Fizz.Steps.Definition, kind: :trigger` macro should wire both behaviours automatically. `Fizz.Triggers.Behaviour` does NOT inherit from or replace the executor behaviour — they are composed via dual `@behaviour` declarations.

```elixir
defmodule Fizz.Triggers.Behaviour do
  @moduledoc """
  Additional behaviour for trigger step executors.

  Trigger steps implement BOTH Fizz.Steps.Executors.Behaviour (execute/3, etc.)
  AND this behaviour. The Step Definition macro wires both when kind: :trigger.
  """

  @doc """
  Returns a registration specification describing what external source
  this trigger listens to.

  Called at publish time (definition-level) and at subscribe time (run-level).
  The platform uses this to create/update entries in the trigger_registrations
  table and start the appropriate listener infrastructure.
  """
  @callback registration_spec(config :: map(), context :: map()) ::
              {:ok, Fizz.Triggers.RegistrationSpec.t()} | {:error, term()}

  @doc """
  Filter predicate for shared channels. When multiple trigger registrations
  share an inbound channel (e.g., a single webhook endpoint receiving events
  from multiple GitHub repos), this callback determines whether a specific
  incoming event matches this trigger's configuration.

  Returns true if the event should fire this trigger. Default: always true.
  """
  @callback match?(config :: map(), incoming_event :: map()) :: boolean()

  @doc """
  Transforms a raw external event into the trigger step's output schema.

  Raw events arrive in provider-specific formats (GitHub webhook JSON,
  Slack Events API payload, raw HTTP body, etc.). This callback extracts
  and reshapes the relevant fields into the schema declared by
  effective_output_schema/1.
  """
  @callback normalize_event(config :: map(), raw_event :: map()) ::
              {:ok, map()} | {:error, term()}

  @optional_callbacks [match?: 2]
end
```

### Registration Specification

```elixir
defmodule Fizz.Triggers.RegistrationSpec do
  @moduledoc """
  Describes what external source a trigger listens to.
  Returned by registration_spec/2 on trigger executors.
  """

  @type kind ::
          :manual
          | :webhook
          | :schedule
          | :polling
          | :subscription
          | :chat

  @type t :: %__MODULE__{
          kind: kind(),
          params: map(),
          dedup_key: String.t() | nil
        }

  defstruct [:kind, :params, :dedup_key]
end
```

**Kind semantics:**

| Kind | What it means | Infrastructure |
|------|--------------|----------------|
| `:manual` | No external source. User-initiated via API/UI. | None — registration is a no-op marker |
| `:webhook` | HTTP POST to a generated URL | `WebhookRouter` plug |
| `:schedule` | Cron expression or interval | `SchedulePoller` GenServer |
| `:polling` | Periodic API polling with cursor | `EventStreamSupervisor` consumer |
| `:subscription` | Push-based subscription (PubSub, reactive) | `EventStreamSupervisor` consumer |
| `:chat` | Conversational session initiation | Chat UI integration |

**Note on composed patterns**: The advanced trigger patterns (persistent connection, presence) do NOT get their own registration kinds. They compose from the kinds above: persistent connections use `:webhook` or `:subscription` plus signals; presence is composed from signals + durable timers. This is deliberate — keeping the kind enum small keeps the infrastructure simple.

---

## 4. Two Registration Scopes

### 4.1 Definition-Level: Always-On Listeners

When a workflow definition version is published, the platform extracts trigger metadata from the compiled Runic workflow and creates persistent registrations.

```
Publish workflow definition version
  → Compiler extracts trigger_manifest from fizz_metadata
  → For each trigger step: call registration_spec(config, definition_context)
  → Upsert trigger_registrations rows in Postgres
  → Notify Fizz.Triggers.Registry via PG LISTEN/NOTIFY
  → Registry loads registrations into ETS
  → Pollers / WebhookRouter / Consumers begin watching

External event arrives
  → Listener (WebhookRouter / SchedulePoller / StreamConsumer)
  → match?(config, event) filter
  → normalize_event(config, event) shaping
  → Enqueue TriggerFireWorker (Oban)
  → Worker creates new workflow_run + starts execution
```

Definition-level registrations are **always on** while the definition version is published. They survive deploys, node failures, and restarts because they're in Postgres.

### 4.2 Run-Level: Dynamic Subscriptions

A running workflow can dynamically subscribe to future events. This is how triggers and signals unify — a run-level trigger is a signal subscription with a registered external source.

```
Running workflow reaches a "wait for external event" step
  → Step emits subscribe intent: {:subscribe, spec}
  → Platform creates trigger_registration with run_id scope
  → Workflow checkpoints and potentially passivates

External event arrives
  → Same listener infrastructure as definition-level
  → TriggerFireWorker finds registration has run_id
  → Instead of creating new run: delivers signal to existing run
  → Run wakes from passivation if needed, resumes execution
```

The routing distinction is one field: `trigger_registrations.run_id`. NULL = create new run. Non-NULL = deliver signal.

### 4.3 Registration Lifecycle

```
                    ┌──────────┐
                    │  created  │
                    └────┬─────┘
                         │ (publish or subscribe)
                    ┌────▼─────┐
              ┌─────│  active   │─────┐
              │     └────┬─────┘     │
              │          │           │
         (pause)    (error x3)   (unpublish/
              │          │        run complete)
         ┌────▼─────┐   │     ┌────▼─────┐
         │  paused   │   │     │ inactive  │
         └────┬─────┘   │     └──────────┘
              │          │
         (resume)   ┌────▼─────┐
              │     │  errored  │
              └─────►          │
                    └──────────┘
```

---

## 5. Multiple Triggers Per Root — Composition Semantics

The constraint "only one trigger per graph root" (from `steps-and-integrations-design.md`) is relaxed. A workflow can have N trigger steps, each a root node (in-degree zero) in the DAG. **Action item**: update `steps-and-integrations-design.md` to reflect this relaxation when implementing. The existing `validate_has_entry_step` already accepts multiple roots structurally.

### 5.1 Any-Of (Default)

Each trigger independently creates a new workflow run when it fires. The trigger that fired provides the initial input fact to its branch of the graph. Other trigger root nodes receive no input and do not activate — this is natural Runic lazy evaluation. A node whose input facts are not satisfied simply never becomes runnable.

**Example**: A "customer support" workflow has both a webhook trigger (from Zendesk) and a manual trigger (from the operator console). Either one can start a case. The workflow definition has two root trigger steps; each independently creates runs.

### 5.2 Clarification: Triggers vs. Signals

Each trigger independently creates a new run. Multi-condition convergence patterns — where a workflow must wait for multiple external conditions before proceeding (e.g., "approval received AND payment confirmed AND identity verified") — belong to the **signal** system, not the trigger system.

A workflow started by a webhook trigger can subsequently wait for approval signals, timer signals, or other external events using signal wait steps. These blocking waits are signals delivered to an already-running workflow, not additional triggers. This keeps the trigger model simple: one trigger fires → one run starts.

---

## 6. Data Model

### 6.1 Postgres: `trigger_registrations`

```sql
CREATE TABLE trigger_registrations (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workflow_definition_id  UUID NOT NULL REFERENCES workflow_definitions(id),
    definition_version_id   UUID NOT NULL REFERENCES workflow_definition_versions(id),
    step_id                 TEXT NOT NULL,
    project_id              UUID NOT NULL REFERENCES projects(id),
    workos_organization_id  TEXT NOT NULL,

    -- Scope: NULL = definition-level (creates new runs), non-NULL = run-level (delivers signals)
    run_id                  UUID REFERENCES workflow_runs(run_id),

    kind                    TEXT NOT NULL
                            CHECK (kind IN ('manual','webhook','schedule',
                                            'polling','subscription','chat')),
    status                  TEXT NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active','paused','errored','inactive','firing')),
    registration_params     JSONB NOT NULL DEFAULT '{}',
    config_digest           TEXT NOT NULL,

    -- Webhook-specific
    webhook_path            TEXT,
    webhook_secret          TEXT,

    -- Schedule-specific
    cron_expression         TEXT,
    next_fire_at            TIMESTAMPTZ,

    -- Polling/Subscription-specific
    cursor                  JSONB,
    poll_interval_ms        INTEGER,
    last_polled_at          TIMESTAMPTZ,
    batch_size              INTEGER DEFAULT 100,

    -- Error tracking
    error_message           TEXT,
    consecutive_errors      INTEGER DEFAULT 0,
    last_error_at           TIMESTAMPTZ,

    inserted_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Unique per step per version (prevent double registration)
CREATE UNIQUE INDEX idx_trigger_reg_dedup
    ON trigger_registrations(definition_version_id, step_id)
    WHERE run_id IS NULL;

-- Unique per step per run (prevent double subscription)
CREATE UNIQUE INDEX idx_trigger_reg_run_dedup
    ON trigger_registrations(run_id, step_id)
    WHERE run_id IS NOT NULL;

-- Webhook routing (fast path lookup)
CREATE UNIQUE INDEX idx_trigger_reg_webhook
    ON trigger_registrations(webhook_path)
    WHERE webhook_path IS NOT NULL AND status = 'active';

-- Schedule polling
CREATE INDEX idx_trigger_reg_schedule_due
    ON trigger_registrations(next_fire_at)
    WHERE kind = 'schedule' AND status = 'active' AND next_fire_at IS NOT NULL;

-- Event stream polling
CREATE INDEX idx_trigger_reg_polling_due
    ON trigger_registrations(last_polled_at)
    WHERE kind = 'polling' AND status = 'active';

-- Project scope for UI queries
CREATE INDEX idx_trigger_reg_project
    ON trigger_registrations(project_id, status);
```

### 6.2 Extension to `workflow_runs`

```sql
ALTER TABLE workflow_runs
    ADD COLUMN triggered_by JSONB;
    -- Structure:
    -- {
    --   "trigger_registration_id": "uuid",
    --   "trigger_step_id": "step-id",
    --   "trigger_kind": "webhook",
    --   "event_id": "dedup-key",
    --   "received_at": "2026-03-18T..."
    -- }
```

### 6.3 Trigger Event Log (for dedup and audit)

```sql
CREATE TABLE trigger_events (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trigger_registration_id UUID NOT NULL REFERENCES trigger_registrations(id),
    project_id              UUID NOT NULL REFERENCES projects(id),
    workos_organization_id  TEXT NOT NULL,
    event_id                TEXT NOT NULL,
    event_data              JSONB,
    status                  TEXT NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending','processing','fired','skipped','failed')),
    run_id                  UUID,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at            TIMESTAMPTZ
);

-- Retention: events older than 7 days in terminal states should be pruned
-- by RegistrationSyncWorker or a dedicated cleanup cron.

-- Dedup: same event doesn't fire twice
CREATE UNIQUE INDEX idx_trigger_events_dedup
    ON trigger_events(trigger_registration_id, event_id);

-- Cleanup: old events can be pruned
CREATE INDEX idx_trigger_events_cleanup
    ON trigger_events(created_at)
    WHERE status IN ('fired','skipped','failed');
```

---

## 7. Supervision Tree

```
Fizz.Application
├── (existing: Repo, PubSub, Oban, Endpoint, ...)
│
├── Fizz.Triggers.Supervisor                    (:rest_for_one)
│   ├── Fizz.Triggers.Registry                  (GenServer)
│   │   Loads active trigger_registrations into ETS on init.
│   │   Indexes by webhook_path, by project_id, by kind.
│   │   Subscribes to PG LISTEN/NOTIFY channel "trigger_registrations".
│   │   Provides lookup APIs for WebhookRouter and pollers.
│   │
│   ├── Fizz.Triggers.SchedulePoller            (GenServer)
│   │   Polls trigger_registrations WHERE kind='schedule'
│   │     AND next_fire_at <= now() AND status = 'active'
│   │   Uses FOR UPDATE SKIP LOCKED for multi-node safety.
│   │   Computes next_fire_at from cron_expression after each fire.
│   │   Enqueues TriggerFireWorker for each due schedule.
│   │   Poll interval: 1s for near-term, 60s sweep.
│   │
│   └── Fizz.Triggers.EventStreamSupervisor     (DynamicSupervisor)
│       Manages long-lived consumer processes for polling/subscription triggers.
│       Each consumer is a GenServer that:
│         - Acquires Postgres advisory lock (registration_id hash)
│         - Polls external API on configured interval
│         - Tracks cursor in trigger_registrations.cursor
│         - Enqueues TriggerFireWorker for each new event
│         - Backs off on consecutive errors
│       └── Fizz.Triggers.Consumers.GenericPoller  (one per active registration)
│       └── Fizz.Triggers.Consumers.GmailWatcher   (provider-specific)
│       └── Fizz.Triggers.Consumers.SlackConsumer   (provider-specific)
│       └── ...
│
├── Fizz.Workflows.Supervisor                    (existing planned)
│   └── ...
```

### Oban Workers

```elixir
# New Oban queue in config
config :fizz, Oban,
  queues: [
    default: 10,
    workspaces: 20,
    workspaces_maintenance: 5,
    triggers: 20                    # new
  ]
```

**`Fizz.Triggers.Workers.TriggerFireWorker`** — the universal trigger-to-run bridge:

```elixir
defmodule Fizz.Triggers.Workers.TriggerFireWorker do
  use Oban.Worker,
    queue: :triggers,
    max_attempts: 5,
    unique: [
      keys: [:trigger_registration_id, :event_id],
      period: 300  # 5-minute dedup window
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "trigger_registration_id" => reg_id,
      "event_id" => event_id,
      "normalized_data" => data
    } = args

    registration = Fizz.Triggers.get_registration!(reg_id)

    case registration.run_id do
      nil ->
        # Definition-level: create a new run
        create_and_start_run(registration, data, event_id)

      run_id ->
        # Run-level: deliver signal to existing run via signal_inbox.
        # This writes to the Postgres signal_inbox table (Section 12 of
        # durable-workflow-system-design.md) and PG NOTIFYs the SignalRouter.
        # The SignalRouter handles wake-up from passivation.
        deliver_signal_via_inbox(run_id, registration, data, event_id)
    end
  end
end
```

**`Fizz.Triggers.Workers.RegistrationSyncWorker`** — reconciliation cron:

```elixir
# Oban cron plugin addition
config :fizz, Oban,
  plugins: [
    {Oban.Plugins.Cron, crontab: [
      # existing...
      {"* * * * *", Fizz.Triggers.Workers.RegistrationSyncWorker}
    ]}
  ]
```

This worker:
1. Finds published definition versions with missing registrations → creates them
2. Finds registrations for unpublished/archived versions → deactivates them
3. Finds errored registrations past cooldown → resets to active
4. Finds active polling registrations without running consumers → signals EventStreamSupervisor to start them

### WebhookRouter

Mounted in the Phoenix router as a plug-based endpoint:

```elixir
# In router.ex
scope "/triggers", FizzWeb do
  pipe_through [:api]
  post "/wh/:webhook_path", Triggers.WebhookController, :receive
end
```

The controller:
1. Looks up registration by `webhook_path` in `Fizz.Triggers.Registry` (ETS, ~1μs)
2. Verifies HMAC signature using `registration.webhook_secret`
3. Calls `trigger_executor.match?(config, raw_body)` — filter
4. Calls `trigger_executor.normalize_event(config, raw_body)` — shape
5. Enqueues `TriggerFireWorker` with the normalized data
6. Returns `202 Accepted` immediately

---

## 8. Trigger Pattern Implementations

### 8.1 Manual Trigger

**What it is**: User clicks "Run" in the UI or calls the API with input data.

**Mapping**: No registration infrastructure needed. The existing `ManualInput` executor's `execute/3` is a passthrough. The "run workflow" API endpoint creates a `workflow_run` directly.

**Registration spec**: `%RegistrationSpec{kind: :manual, params: %{}}` — a marker that tells the UI this workflow can be manually triggered and what input schema to present.

**Executor contract**: `execute(config, user_provided_input, context)` → `{:ok, user_provided_input}`

**Use cases**: Testing/debugging workflows, one-off data processing, operator-initiated remediation.

### 8.2 Webhook Trigger

**What it is**: HTTP POST to a generated URL starts a new run or signals an existing one.

**Mapping**: Publishing a workflow with a webhook trigger creates a `trigger_registration` with a unique `webhook_path` (random token, e.g., `wh_7kB3mQ9xPn`). The `WebhookRouter` plug handles inbound requests.

**New infrastructure**: `Fizz.Triggers.WebhookController`, webhook path generation, HMAC signing.

**Registration spec**:
```elixir
def registration_spec(config, _context) do
  {:ok, %RegistrationSpec{
    kind: :webhook,
    params: %{
      http_methods: config["http_methods"] || ["POST"],
      headers_to_extract: config["headers"] || [],
      signature_header: config["signature_header"],
      signature_algorithm: config["signature_algorithm"] || "hmac-sha256"
    }
  }}
end
```

**Executor contract**: `execute(config, normalized_webhook_payload, context)` → `{:ok, output}`. The `normalized_webhook_payload` has already been shaped by `normalize_event/2`.

**Integration triggers** (GitHub, Slack, Notion, etc.) are specialized webhook triggers. Each implements `normalize_event/2` to extract relevant fields from the provider's payload format, and `match?/2` to filter events by type (e.g., only `push` events, only messages in a specific channel).

**Use cases**: GitHub push → deploy workflow, Stripe payment → fulfillment workflow, Zendesk ticket → support triage workflow.

### 8.3 Schedule/Cron Trigger

**What it is**: Time-based recurring execution — every N seconds, or a cron expression.

**Mapping**: `trigger_registrations` with `kind = 'schedule'`, `cron_expression`, and `next_fire_at`. The `SchedulePoller` is structurally identical to the `TimerPoller` from the durable system design (Section 11), but operates on `trigger_registrations` instead of `durable_timers`.

**Registration spec**:
```elixir
def registration_spec(config, _context) do
  {:ok, %RegistrationSpec{
    kind: :schedule,
    params: %{
      cron: config["cron_expression"],        # "0 9 * * MON-FRI"
      interval_seconds: config["interval_seconds"],  # alternative: every N seconds
      timezone: config["timezone"] || "UTC",
      jitter_seconds: config["jitter_seconds"] || 0
    }
  }}
end
```

**Schedule computation**: After each fire, compute next occurrence from cron expression. Store as `next_fire_at`. The poller query is:

```sql
UPDATE trigger_registrations
SET status = 'firing'  -- temporary lock
WHERE id IN (
    SELECT id FROM trigger_registrations
    WHERE kind = 'schedule'
      AND status = 'active'
      AND next_fire_at <= now()
    ORDER BY next_fire_at
    LIMIT 50
    FOR UPDATE SKIP LOCKED
)
RETURNING *;
```

After enqueueing the `TriggerFireWorker`, update `next_fire_at` and reset status to `active`.

**Executor contract**: `execute(config, %{"scheduled_at" => iso8601, "occurrence" => n}, context)` → `{:ok, output}`

**Use cases**: Daily report generation, hourly data sync, weekly cleanup job, market-hours-only trading workflows.

### 8.4 Chat Trigger

**What it is**: A conversational session starts a workflow run. Subsequent messages are signals to the running workflow.

**Mapping**: The chat trigger bridges two models — the first message creates a new run (definition-level), and all subsequent messages in the same conversation deliver signals to that run (run-level). The `on_chat_trigger` step's output is the initial message. The workflow can contain "wait for next message" steps that subscribe to the chat channel for run-level signals.

**Registration spec**:
```elixir
def registration_spec(config, _context) do
  {:ok, %RegistrationSpec{
    kind: :chat,
    params: %{
      session_scope: config["session_scope"] || "per_user",  # per_user | per_channel | per_thread
      greeting: config["greeting"],
      input_schema: config["input_schema"]
    }
  }}
end
```

**Session management**: The chat UI (Phoenix LiveView or channel) maps `(user_id, workflow_definition_id, session_scope)` to a run. If no active run exists for that scope, the first message creates one. If an active/sleeping run exists, the message is delivered as a signal.

**Executor contract**: `execute(config, %{"message" => text, "sender" => user, "session_id" => id}, context)` → `{:ok, output}`

**Use cases**: AI assistant workflows, interactive onboarding, conversational data collection, customer support chat bots.

### 8.5 Persistent Connection Trigger

**What it is**: A WebSocket or SSE connection keeps a workflow hot. Disconnection triggers passivation. Reconnection wakes the workflow.

**Mapping**: Composed entirely from existing primitives — no new trigger kind needed.

- **Connect** = run-level signal (`"client_connected"`) delivered via the signal inbox
- **Heartbeat** = periodic `last_active_at` updates on the workflow_run row, suppressing the PassivationSweeper
- **Disconnect** = heartbeat stops. PassivationSweeper transitions the run through tiers (hot → warm → cold) on its normal schedule
- **Reconnect** = signal to the signal inbox, which wakes the run from whatever passivation tier it reached

The Phoenix channel/LiveView that manages the client connection is responsible for sending connect/disconnect signals and maintaining the heartbeat. The workflow itself uses standard "wait for signal" steps to handle connection lifecycle events.

```
Browser connects via WebSocket
  → Phoenix Channel join
  → Signal "client_connected" to run (creates run if first connection)
  → Workflow moves to hot tier, starts executing

Browser tab stays open
  → Channel sends heartbeat every 30s
  → Updates workflow_run.last_active_at
  → PassivationSweeper skips this run

User closes tab
  → Channel terminate callback
  → Heartbeat stops
  → After idle threshold (e.g., 10 min): PassivationSweeper passivates
  → Run sleeps in S3

User returns days later, opens tab
  → Channel join
  → Signal "client_connected" to sleeping run
  → Run wakes from S3, resumes with full state
```

**Use cases**: Multiplayer game sessions, collaborative document editing, real-time dashboards with server-side state, interactive data exploration sessions.

### 8.6 Event Stream Trigger

**What it is**: Workflows that wake on external events matching a pattern, process a batch, then sleep again. Supports Kafka, NATS, PubSub, or any API with cursor-based pagination.

**Mapping**: `kind: :polling` registration. A consumer GenServer per active registration, managed by `EventStreamSupervisor`. The consumer polls an external API, tracks its cursor, and enqueues trigger fires.

**Registration spec**:
```elixir
def registration_spec(config, _context) do
  {:ok, %RegistrationSpec{
    kind: :polling,
    params: %{
      source: config["source"],                  # "gmail" | "kafka" | "nats" | "custom_api"
      poll_interval_ms: config["poll_interval_ms"] || 30_000,
      batch_size: config["batch_size"] || 100,
      filter: config["filter"],                  # source-specific filter expression
      cursor_init: config["cursor_init"],         # initial cursor value
      backpressure_max_pending: config["max_pending"] || 1000,
      credentials_ref: config["credentials_ref"]  # reference to integration credential
    }
  }}
end
```

**Consumer lifecycle**:

```
EventStreamSupervisor starts consumer GenServer
  → Consumer acquires Postgres advisory lock (hash of registration_id)
  → If lock acquired: begin polling loop
  → If lock not acquired: another node owns this consumer, exit normally

Polling loop:
  1. Check backpressure: count pending runs for this registration
     If count >= max_pending → sleep poll_interval_ms, retry
  2. Fetch batch from external source using cursor
  3. For each event in batch:
     a. Call normalize_event(config, raw_event)
     b. Enqueue TriggerFireWorker with normalized data
  4. Update cursor in trigger_registrations.cursor (atomic)
  5. Sleep poll_interval_ms
  6. Loop
```

**Cursor management**: The cursor is stored as JSONB in `trigger_registrations.cursor`. Format is source-specific (offset for Kafka, historyId for Gmail, timestamp for generic APIs). On crash/restart, the consumer resumes from the persisted cursor.

**Batch semantics**: Two modes controlled by config:
- **Per-event fire** (default): Each event in the batch creates a separate workflow run
- **Batch fire**: The entire batch is delivered as a single input array to one workflow run. Useful for aggregation workflows.

**Adaptive polling**: The consumer can adjust its poll interval based on event frequency. If the last N polls returned zero events, double the interval (up to a max). If events are flowing, use the base interval. This reduces API quota consumption during quiet periods.

**Use cases**: Email processing (Gmail API polling), Slack message aggregation, IoT sensor data batching, log analysis pipelines, RSS/Atom feed monitoring.

### 8.7 Reactive Trigger

**What it is**: A workflow that watches another workflow's state changes or completion.

**Mapping**: `kind: :subscription` with a source descriptor pointing at workflow lifecycle events.

**Registration spec**:
```elixir
def registration_spec(config, _context) do
  {:ok, %RegistrationSpec{
    kind: :subscription,
    params: %{
      source: :workflow_lifecycle,
      watch_definition_id: config["watch_definition_id"],
      watch_statuses: config["watch_statuses"] || ["COMPLETED"],
      filter: config["filter"]  # optional: match on metadata
    }
  }}
end
```

**Implementation**: When a workflow run transitions to a watched status, the run lifecycle code (`Fizz.Workflows.on_workflow_complete/1` or status transition hooks) queries for matching reactive trigger registrations:

```sql
SELECT * FROM trigger_registrations
WHERE kind = 'subscription'
  AND status = 'active'
  AND registration_params->>'source' = 'workflow_lifecycle'
  AND registration_params->>'watch_definition_id' = ?
  AND registration_params->'watch_statuses' ? ?  -- contains status
```

Matching registrations fire via `TriggerFireWorker` with the completed run's metadata as the event payload.

**Use cases**: Pipeline orchestration (workflow B starts when workflow A completes), error alerting (notification workflow triggers when any workflow fails), audit trail (logging workflow captures all workflow completions).

### 8.8 Long-Poll / Presence Trigger

**What it is**: A collaborative session where the workflow is shared state, kept warm by participant presence, passivated when everyone leaves.

**Mapping**: Composed entirely from signals + timers, matching the persistent connection pattern (Section 8.5) but with multi-participant semantics.

- Each participant's connection sends `"participant_joined"` / `"participant_left"` signals
- A participant counter (Runic Accumulator step) tracks active count
- When count reaches 0: a durable timer starts (grace period before passivation)
- If a participant joins before the timer fires: timer is cancelled, workflow stays hot
- If timer fires with count still 0: workflow passivates

**No new primitive needed**. The workflow author builds this from: trigger (any kind) + accumulator + durable timer + signal waits.

**Use cases**: Collaborative whiteboard sessions, shared game state, live polling/voting, pair programming environments.

---

## 9. Compiler Integration

### 9.1 Normalizer Changes

In the normalization phase (`lib/fizz/workflows/compiler/normalizer.ex`), after `find_entry_steps/2`:

1. **Validate trigger placement**: All steps with `kind: :trigger` must be graph roots (in-degree zero). A trigger step with incoming connections is a compiler error.

### 9.2 Assembler Changes

The assembler adds a `trigger_manifest` to the workflow's `fizz_metadata`:

```elixir
%{
  compiler_version: 2,  # bumped from 1 — trigger manifest is a new assembly output
  trigger_manifest: [
    %{
      step_id: "uuid-1",
      type_id: "webhook_trigger",
      config: %{...},
    },
    %{
      step_id: "uuid-2",
      type_id: "schedule_trigger",
      config: %{...}
    }
  ]
}
```

Trigger steps are assembled as normal Runic components (Step or Rule nodes). Their `execute/3` receives the normalized trigger data as input, which is injected as an external fact when the trigger fires.

### 9.3 Publish Hook

When a definition version transitions to `:published`:

```elixir
defmodule Fizz.Triggers.RegistrationManager do
  def sync_on_publish(definition_version) do
    manifest = definition_version.compiled_workflow.fizz_metadata.trigger_manifest

    for trigger <- manifest do
      executor = Fizz.Steps.Registry.get_executor(trigger.type_id)
      {:ok, spec} = executor.registration_spec(trigger.config, build_context(definition_version))

      upsert_registration(%{
        workflow_definition_id: definition_version.workflow_definition_id,
        definition_version_id: definition_version.id,
        step_id: trigger.step_id,
        project_id: definition_version.project_id,
        kind: spec.kind,
        registration_params: spec.params,
        config_digest: hash(spec),
      })
    end

    # Deactivate registrations from previous published versions
    deactivate_stale_registrations(definition_version)
  end
end
```

---

## 10. Deploy Survival and Node Failure Recovery

| Concern | Mechanism |
|---------|-----------|
| Registration persistence | Postgres `trigger_registrations` — survives any deploy/failure |
| Schedule firing | `SchedulePoller` uses `FOR UPDATE SKIP LOCKED` — multi-node safe, no double-fires |
| Stream consumers | Advisory lock per registration_id — prevents duplicate consumers across nodes |
| Webhook routing | `Fizz.Triggers.Registry` loads from Postgres into ETS — any node handles any webhook |
| Registry sync | LISTEN/NOTIFY for real-time + periodic full sync as fallback |
| Consumer restart | `RegistrationSyncWorker` (Oban cron) detects orphaned registrations and signals `EventStreamSupervisor` |

---

## 11. Deduplication

Three layers:

1. **Event-level**: Each trigger event gets an `event_id` (provider-supplied where available, or content hash). Oban's unique job constraint on `(trigger_registration_id, event_id)` prevents double-firing within a 5-minute window. The `trigger_events` table provides a longer-term dedup log.

2. **Registration-level**: `config_digest` on `trigger_registrations` prevents semantically duplicate registrations. The unique index on `(definition_version_id, step_id)` prevents structural duplicates.

3. **Signal-level**: Uses the existing signal inbox dedup contract — `(run_id, signal_id)` scoped uniqueness.

---

## 12. Patterns Uniquely Enabled by Durable Execution

These patterns are impossible or impractical on conventional workflow platforms because they require cheap long-term sleep with instant resumability.

### 12.1 Hibernating Watchers

A webhook-triggered workflow publishes and immediately sleeps. Its registration sits in Postgres; no compute resources consumed. The SQLite file doesn't even exist yet — there's no run until the webhook fires. When it does, months later, the run is created fresh.

**Cost**: ~$0/month for a dormant trigger registration (it's a Postgres row).

### 12.2 Cumulative Triggers

A single trigger (e.g., webhook or polling) starts a workflow run that accumulates events over days or weeks. Subsequent events arrive as signals to the running workflow, updating an Accumulator step. A durable timer fires periodically to check if the accumulation threshold is met. If yes, the workflow proceeds. If no, it resets the timer and sleeps again.

**Example**: "Alert me when total API errors from three different services exceed 1000 in a rolling 7-day window." — a webhook trigger starts the run on the first error event; subsequent errors arrive as signals.

### 12.3 Session Resumption

A chat-triggered workflow passivates when the user stops messaging. Days later, the user returns. The chat trigger finds the existing sleeping run for that user/session scope and delivers the new message as a signal. The workflow wakes with full conversation history and accumulated state intact.

**Example**: Multi-day onboarding flow where users complete steps at their own pace.

### 12.4 Cross-Workflow Choreography

Reactive triggers create event-driven choreography between independent workflows. Workflow A completes → reactive trigger fires → Workflow B starts → B completes → reactive trigger fires → Workflow C starts. No central orchestrator. Each workflow is independently authored, deployed, and versioned. The reactive trigger registrations are the wiring.

**Example**: Microservice-style decomposition of a complex business process where different teams own different workflows.

### 12.5 Tidal Workflows

Event stream triggers with adaptive polling. During high-traffic hours, the consumer polls every 5 seconds and creates runs aggressively. During quiet hours, it polls every 5 minutes. The workflow processes surge naturally through Oban's backpressure, and pending runs queue without data loss.

**Example**: E-commerce order processing that handles Black Friday surges without configuration changes.

### 12.6 Sentinel Patterns

A workflow that watches a condition (via polling trigger) and only proceeds when the condition becomes true. While waiting, it costs nothing — the trigger registration polls, but the workflow itself doesn't exist as a run until the condition is met.

**Example**: "Start the migration workflow when the staging database size drops below 10GB" — the polling trigger checks the DB size API hourly. When the condition is met, the workflow run is created.

---

## 13. Security

### 13.1 Webhook Security

- **HMAC verification**: Each webhook registration generates a unique secret. Inbound requests must include a valid HMAC signature in a configurable header. The `WebhookController` verifies before processing.
- **Rate limiting**: Per-registration rate limits prevent abuse. Configurable in `registration_params`.
- **Path unpredictability**: Webhook paths are cryptographically random tokens (not sequential or guessable).
- **TLS only**: Webhook URLs are HTTPS in production.

### 13.2 Authorization

- Trigger registrations inherit project-level authorization from the workflow definition
- The `WebhookController` does NOT require user authentication (it's a machine-to-machine endpoint) but validates the HMAC signature
- All other trigger operations (create, pause, delete, list) require project membership via `%Fizz.Accounts.Scope{}`
- Run-level trigger subscriptions inherit authorization from the creating run's project scope

### 13.3 Credential Isolation

- Polling trigger consumers that access external APIs use `credentials_ref` to fetch tokens via `Fizz.Integrations.get_token/2`
- Credentials are never stored in `trigger_registrations` — only references
- Each consumer fetches fresh tokens at poll time

---

## 14. Observability

### 14.1 Metrics

```
fizz.triggers.registration.count          (gauge, by kind + status + project)
fizz.triggers.fire.count                  (counter, by kind + project)
fizz.triggers.fire.latency                (histogram — event received to run started)
fizz.triggers.webhook.response_time       (histogram)
fizz.triggers.schedule.fire_lag           (histogram — scheduled_at vs actual)
fizz.triggers.polling.events_per_poll     (histogram)
fizz.triggers.polling.cursor_lag          (gauge — how far behind the consumer is)
fizz.triggers.error.count                 (counter, by kind + error_type)
```

### 14.2 Structured Logging

Every trigger fire produces a structured log entry with: `trigger_registration_id`, `event_id`, `kind`, `project_id`, `latency_ms`, and outcome (`run_created | signal_delivered | deduped | error`).

---

## 15. Rollout Plan

### Phase 1: Foundation

- `Fizz.Triggers.Behaviour` module
- `Fizz.Triggers.RegistrationSpec` struct
- `trigger_registrations` and `trigger_events` Ecto schemas + migrations
- `Fizz.Triggers.Registry` GenServer (ETS-backed)
- `Fizz.Triggers.Supervisor` in application tree
- `Fizz.Triggers.Workers.TriggerFireWorker` Oban worker
- `Fizz.Triggers.Workers.RegistrationSyncWorker` Oban cron

### Phase 2: Basic Triggers

- Manual trigger: wire run creation API to trigger manifest
- Webhook trigger: `WebhookController`, path generation, HMAC verification
- Schedule trigger: `SchedulePoller`, cron expression parsing
- Update existing trigger executors to implement `registration_spec/2` and `normalize_event/2`
- Compiler integration: trigger_manifest extraction, publish hook

### Phase 3: Advanced Triggers

- Event stream consumers: `EventStreamSupervisor`, `GenericPoller`, cursor management
- Run-level subscriptions: dynamic registration creation, signal delivery path
- Chat trigger: session management, message-as-signal delivery
- Reactive trigger: workflow lifecycle hooks, subscription matching

### Phase 4: Integration Triggers

- GitHub webhook trigger (push, PR, issue events)
- Slack Events API trigger
- Gmail push notification trigger
- Remaining integration triggers (Notion, Google Sheets, etc.)
- Provider-specific `normalize_event/2` implementations

### Phase 5: Presence and Connection Patterns

- Phoenix Channel/LiveView integration for persistent connection signals
- Heartbeat → last_active_at bridge
- Documentation and examples for composed presence patterns
