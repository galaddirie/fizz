# Runic Durable Workflow Orchestration Assessment

## 1. Runic suitability assessment

### Bottom line

Runic is a credible **workflow execution kernel** for a durable orchestration platform, but it is **not** a durable orchestration engine by itself.

The right way to use it is:

- `Runic.Workflow` as the in-memory graph evaluator, dependency resolver, and workflow composition model
- custom `Invokable` nodes as the extension point for orchestration-specific semantics
- `Runic.Runner` only for local execution, experiments, or short-lived managed runs

The wrong way to use it is:

- treating `Runic.Runner` as the durable control plane for workflows that must survive months of dormancy, external signals, human approvals, and repeated redeploys

Runic is strongest where the platform needs:

- runtime workflow composition and mutation
- graph-based dependency resolution
- fan-out, fan-in, and join semantics inside a single execution graph
- stateful nodes such as accumulators and state machines
- an execution model that separates prepare, execute, and apply
- the ability to rehydrate workflow state from serialized history

That is explicit in the docs and implementation:

- Runic positions itself as a “data driven workflow” tool with runtime composition and lazy concurrent execution: `runic/README.md:5-9`, `runic/README.md:185-216`
- the scheduler guide presents Runic as a **process-agnostic data structure** with a three-phase dispatch model: `runic/guides/scheduling.md:3-6`, `runic/guides/scheduling.md:89-156`
- the protocols guide makes `Invokable` the core runtime extension point for custom node behavior: `runic/guides/protocols.md:16-84`

### Capability-by-capability assessment

| Requirement | Native Runic support | Assessment |
| --- | --- | --- |
| Dynamic workflow graph / runtime composition | Strong | One of Runic's best fits. `Workflow.add/3`, `Workflow.merge/2`, and custom components make it a good execution kernel for runtime-defined workflows. Sources: `runic/README.md:185-206`, `runic/lib/workflow.ex:353-615`. |
| Long-lived execution state | Partial | State can be serialized and rebuilt via `Workflow.log/1` and `Workflow.from_log/1`, but the current persistence model is full-log checkpointing, not a purpose-built long-lived instance runtime. Sources: `runic/lib/workflow.ex:714-808`, `runic/guides/durable-execution.md:24-56`. |
| Event-driven resumption | Partial | The model can resume by rehydrating workflow state and feeding new inputs, but there is no first-class signal API or waiting-state abstraction. Sources: `runic/lib/runic/runner.ex:81-180`, `runic/guides/durable-execution.md:402-423`. |
| Timers / delayed continuation | Weak | There is deadline support for bounded execution, but no durable timers, sleep primitives, wake-up queue, or delayed continuation subsystem. Sources: `runic/lib/workflow/policy_driver.ex:211-260`, `runic/guides/durable-execution.md:244-258`. |
| Human-in-the-loop pauses | Weak | Docs cite approval workflows as a motivation, but there is no human-task model, signal inbox, or approval/task persistence in the runtime. Sources: `runic/guides/durable-execution.md:9-16`, `runic/lib/runic/runner.ex:61-180`. |
| Crash recovery | Partial | Checkpoint and resume exist, but current "durable" recovery is weaker than claimed for truly in-flight work because dispatch events are not persisted before execution starts. Sources: `runic/lib/runic/runner/worker.ex:199-223`, `runic/lib/workflow/policy_driver.ex:98-163`. |
| State persistence / rehydration / replay | Moderate | It works, but replay cost and snapshot size grow with workflow history because the whole execution log is rebuilt and the store rewrites the full log blob. Sources: `runic/lib/workflow.ex:730-808`, `runic/lib/runic/runner/worker.ex:373-394`, `runic/lib/runic/runner/store/ets.ex:22-33`, `runic/lib/runic/runner/store/mnesia.ex:62-78`. |
| Retries / timeout / fallback | Strong | Policies are concrete and implemented. Runic can wrap execution with retries, backoff, timeouts, and fallback output synthesis. Sources: `runic/lib/workflow/scheduler_policy.ex:1-219`, `runic/lib/workflow/policy_driver.ex:57-205`. |
| Exactly-once / effectively-once semantics | Weak | Stable runnable IDs exist, but exactly-once is not implemented, `idempotency_key` is unused, and side-effect dedupe is left to the surrounding system. Sources: `runic/lib/workflow/runnable.ex:47-83`, `runic/lib/workflow/scheduler_policy.ex:62-109`, `runic/lib/workflow/policy_driver.ex:203-205`. |
| Parent/child workflows | Weak | Runic has intra-graph join/fan-out/fan-in, but no first-class parent/child workflow instance model. Sources: `runic/guides/protocols.md:72-84`, `runic/lib/workflow/invokable.ex:1049-1455`, `runic/lib/runic/runner.ex:61-180`. |
| Efficient dormant executions | Weak | The built-in Worker stays alive and just becomes `:idle`; it does not auto-unload dormant instances. Sources: `runic/lib/runic/runner/worker.ex:267-305`. |

### Role Runic can realistically play

Runic can be the platform's:

- workflow graph VM
- dependency and concurrency planner
- local state transition engine
- rule/state-machine evaluator
- workflow-definition runtime for dynamic graphs

Runic should not be the platform's:

- durable timer service
- signal router
- human task service
- append-only execution journal
- instance lifecycle database
- lease-based activity scheduler
- query/audit control plane


## 2. Core gaps or risks

### 2.1 "Durable" dispatch is persisted too late

This is the most important issue.

`PolicyDriver.execute(..., emit_events: true)` constructs `%RunnableDispatched{}` in the task process and returns it only with the final task result: `runic/lib/workflow/policy_driver.ex:98-163`. The Worker appends those events to workflow state only inside `handle_task_result/4`, after the task replies: `runic/lib/runic/runner/worker.ex:199-223`.

That means:

- a worker crash
- VM crash
- node restart

that happens **after dispatch but before task completion message handling** can lose the only durable record that the activity was ever started.

The docs say durable events “enable crash recovery” by identifying in-flight work from dispatched-vs-completed events: `runic/guides/durable-execution.md:58-110`. The implementation does not write that dispatch intent ahead of time.

For a real orchestration engine, dispatch intent must be durably recorded **before** the side effect or activity execution begins.

### 2.2 The built-in Runner is a process manager, not a dormant-instance runtime

Each workflow is a dedicated `GenServer` under a `DynamicSupervisor`: `runic/lib/runic/runner.ex:37-47`, `runic/lib/runic/runner/worker.ex:1-85`.

When the workflow finishes current work, the Worker becomes `:idle`, persists if configured, and remains alive: `runic/lib/runic/runner/worker.ex:267-305`.

That is acceptable for active short-lived runs. It is the wrong model for:

- hundreds of thousands of dormant instances
- month-long waiting workflows
- timer-heavy orchestration
- approval flows that spend 99.9% of their lifetime waiting

You need unloadable dormant instances, not one OTP process per mostly-sleeping workflow.

### 2.3 Persistence is checkpointed full-log rewrite, not a real append-only event journal

`Workflow.log/1` returns `build_log ++ reactions_occurred ++ runnable_events`: `runic/lib/workflow.ex:787-808`.

Every checkpoint/save writes the full log blob:

- checkpoint: `runic/lib/runic/runner/worker.ex:373-385`
- save on idle/stop: `runic/lib/runic/runner/worker.ex:391-394`

Store adapters then overwrite the latest record:

- ETS: `runic/lib/runic/runner/store/ets.ex:22-33`
- Mnesia: `runic/lib/runic/runner/store/mnesia.ex:62-78`

Implications:

- write amplification grows with history length
- snapshots get larger over time
- there is no durable per-event commit boundary
- audit/event queries require loading a large serialized blob
- replay and recovery are coupled to replaying the whole stored workflow log

That is not the storage model you want for a production orchestration control plane.

### 2.4 No first-class timer, signal, or waiting-state model

The runtime exposes:

- `run/4` to feed input
- `resume/3` to reconstruct from stored log
- `checkpoint/2` and `stop/3`

but not:

- `signal(instance_id, signal_name, payload, idempotency_key)`
- `pause(instance_id, reason)`
- `schedule_timer(instance_id, due_at, signal)`
- `cancel_timer`
- `await_human_task`

Sources: `runic/lib/runic/runner.ex:61-180`.

Runic's protocol allows `prepare/3` to return `{:defer, reducer_fn}` in theory: `runic/guides/protocols.md:40-66`, `runic/lib/workflow/invokable.ex:40-56`. But there are no built-in orchestration primitives implementing durable wait behavior, and no library-level timer subsystem using that hook. A search of `runic/lib` shows `{:defer, ...}` only in the protocol and workflow plumbing, not in concrete built-ins.

### 2.5 Replay depends on evaluating stored closures and AST against current code

`Workflow.from_log/1` reconstructs components by calling `Closure.eval/1` or `Code.eval_quoted/3`: `runic/lib/workflow.ex:655-712`, `runic/lib/workflow.ex:730-768`.

`Runic.Closure` stores quoted AST plus bindings and reconstructs an eval environment at replay time: `runic/lib/closure.ex:1-138`.

This is convenient for library ergonomics. It is risky for workflows that live across:

- code upgrades
- refactors
- removed modules/imports
- changing business logic
- security boundaries

For month-long workflows, you want immutable workflow-definition versions, not replay that depends on current runtime code being able to re-evaluate old closure source.

### 2.6 Exactly-once semantics are not present

Runic gives you:

- stable runnable IDs derived from `{node.hash, fact.hash}`: `runic/lib/workflow/runnable.ex:47-83`
- retry/backoff/fallback behavior: `runic/lib/workflow/policy_driver.ex:57-205`

It does **not** give you:

- transactional outbox/inbox semantics
- durable dedupe ledger for external side effects
- activity leases
- completion dedupe
- exactly-once execution

`SchedulerPolicy` defines `idempotency_key`, but it is not used operationally and is stripped from serialized policy data in emitted events: `runic/lib/workflow/scheduler_policy.ex:62-109`, `runic/lib/workflow/policy_driver.ex:203-205`.

The best you can claim with the current runtime is "retries are supported; effectively-once is the caller's job."

### 2.7 No parent/child workflow execution model

Runic supports:

- `Join`
- `FanOut`
- `FanIn`
- stateful nodes

inside a single graph: `runic/guides/protocols.md:68-84`, `runic/lib/workflow/invokable.ex:1049-1455`.

It does not provide:

- child instance spawning with durable linkage
- child completion/cancellation propagation
- parent awaiting child completion as a first-class primitive
- fleet-level coordination across many workflow instances

That all has to be built above the graph runtime.

### 2.8 History and memory growth are real concerns

Runic stores execution state inside the graph and derives the persisted log from that graph: `runic/lib/workflow.ex:787-829`.

There is a `purge_memory/1` helper: `runic/lib/workflow.ex:1985-2022`. That is manual memory relief, not orchestration-grade retention management. It also changes what remains in graph memory.

For long-lived workflows you need:

- snapshots
- retention policies
- event compaction
- history pagination
- summarized current state

Runic does not provide those control-plane features.

### 2.9 The test coverage overstates the crash-recovery story

The "in-flight recovery" test in `runic/test/runner/durable_execution_test.exs` waits until the workflow is already idle, then stops and resumes it: `runic/test/runner/durable_execution_test.exs:168-193`.

That validates reconstruction after completion. It does **not** validate the critical production case:

- task dispatched
- worker/VM crashes before dispatch intent is durably stored
- workflow resumes and avoids duplicate or lost side effects

This gap matters.


## 3. Capabilities required in the surrounding platform

If Runic is the runtime kernel, the surrounding platform still needs all of the following:

### 3.1 Versioned workflow definition service

Store immutable workflow definitions separately from workflow instances.

Requirements:

- workflow type + version
- metadata about compatible upgrades
- serialized Runic graph template or DSL source
- deployment/code artifact version
- node catalog for UI and observability

Do not let running instances depend on "whatever the current app code evaluates."

### 3.2 Durable workflow instance registry

A database-backed instance table should track:

- `instance_id`
- `workflow_type`
- `workflow_version`
- `status`
- `wait_reason`
- `next_wakeup_at`
- `snapshot_ref`
- `last_event_seq`
- `lease_owner`
- `lease_expires_at`
- `created_at` / `updated_at`

Statuses should include:

- `RUNNABLE`
- `WAITING_SIGNAL`
- `WAITING_TIMER`
- `WAITING_HUMAN`
- `PAUSED`
- `FAILED`
- `COMPLETED`
- `CANCELLED`

### 3.3 Append-only execution log

You need a real event table, not only a serialized workflow blob.

The log should record:

- instance lifecycle events
- external signal ingestion
- timer scheduling and firing
- activity scheduling, start, heartbeat, completion, failure
- human task creation and completion
- child workflow start/completion
- workflow patch/migration events
- snapshot creation events

Each event needs:

- monotonically increasing sequence number
- causation ID
- correlation ID
- idempotency key
- actor/user/service identity
- timestamp
- payload hash

### 3.4 Durable timer subsystem

This must be separate from Runic execution.

Requirements:

- `timers` table keyed by instance and timer ID
- `due_at`
- dedupe key
- cancellation support
- wake-up scanner using leases or `SKIP LOCKED`
- conversion of due timers into workflow signals

Timers must not be implemented by `Process.sleep/1`.

### 3.5 Signal ingestion and routing

You need a durable inbox for:

- webhooks
- internal events
- manual/operator actions
- activity completions
- human approvals
- child workflow completions

Signal ingestion must:

- accept idempotency keys
- persist before acknowledge
- route to the correct instance
- support correlation by business key
- wake dormant instances

### 3.6 Activity execution subsystem

External side effects need a separate activity model with:

- scheduled activity records
- worker leases
- heartbeat support
- timeouts
- retries
- dedupe keys
- compensation hooks

Runic should decide **that** an activity must happen. The activity system should durably own **how** it happens.

### 3.7 Human task subsystem

For approvals and manual input, you need:

- task table
- assignee / group / permissions
- form schema / payload schema
- SLA / timeout / escalation
- audit trail
- signal emission back to the workflow when completed

### 3.8 Snapshot and compaction strategy

Use snapshots to bound replay.

A production design should support:

- snapshot every N events or after every activation
- separate current-state summary table
- log compaction rules
- archival of cold histories
- fast resume from latest snapshot plus event tail

### 3.9 Query and control APIs

Operators and applications need APIs for:

- start instance
- get instance status
- get current wait reason
- fetch timeline/history
- signal instance
- pause/resume/cancel/retry
- patch/migrate instance
- list pending human tasks
- inspect pending timers and activities

### 3.10 Observability and auditability

Need:

- OpenTelemetry traces per activation/activity
- metrics on queue depth, timer lag, stuck instances, replay time, activity latency
- audit trail for every operator and user action
- visualization of current Runic graph state
- timeline view joining platform events with Runic outputs


## 4. Proposed system architecture

### 4.1 Architectural position of Runic

Use Runic as the **decision/runtime engine inside an activation**, not as the durable scheduler.

The platform architecture should look like this:

```text
                    +-----------------------------+
                    |  Workflow Definition Store  |
                    |  type + version + template  |
                    +-------------+---------------+
                                  |
                                  v
+-----------+    +----------------+----------------+    +--------------------+
| API / CLI  |--> |  Orchestration Control Plane    |--> | Query / Audit API  |
| Webhooks    |    |  start/signal/pause/resume     |    | timeline/debugging |
+-----------+    +----------------+----------------+    +--------------------+
                                  |
                                  v
                    +-------------+---------------+
                    |  Postgres Event Store       |
                    |  append-only instance log   |
                    +------+------+---------------+
                           |      |
                           |      +----------------------+
                           |                             |
                           v                             v
                 +---------+--------+          +---------+--------+
                 | Snapshot Store   |          | Timer / Inbox    |
                 | current state    |          | timers/signals   |
                 +---------+--------+          +---------+--------+
                           |                             |
                           +-------------+---------------+
                                         |
                                         v
                           +-------------+---------------+
                           | Activation Engine           |
                           | lease instance, rehydrate,  |
                           | run Runic, emit commands    |
                           +------+------+---------------+
                                  |      |
                                  |      +------------------------------+
                                  |                                     |
                                  v                                     v
                       +----------+---------+               +-----------+-----------+
                       | Activity Workers   |               | Human Task Service    |
                       | external side fx   |               | approvals/manual data |
                       +--------------------+               +-----------------------+
```

### 4.2 Workflow runtime model

Each workflow instance is processed in short-lived **activations**:

1. lease instance row
2. load latest snapshot plus any un-applied events/signals
3. reconstruct Runic workflow state
4. inject new signals as facts or orchestration command inputs
5. run Runic until quiescent
6. interpret emitted command facts
7. append platform events and persist new snapshot transactionally
8. release lease and exit

This is the key operational shift:

- **no permanent `GenServer` per dormant execution**
- **no compute held open while waiting**
- **all waits represented durably in storage**

### 4.3 Durable state storage

Use Postgres as the primary control-plane database.

Recommended tables:

- `workflow_definitions`
- `workflow_instances`
- `workflow_events`
- `workflow_snapshots`
- `workflow_signals`
- `workflow_timers`
- `workflow_activities`
- `workflow_human_tasks`
- `workflow_outbox`

Store two forms of state:

- platform-native normalized state for querying and control
- a serialized Runic snapshot for fast rehydration

The serialized Runic snapshot can be:

- a full `Workflow.log/1` blob for a first implementation
- later replaced by a more compact template-plus-instance-state representation

### 4.4 Append-only execution history

The platform event log, not the Runic graph, is the source of truth.

Example event types:

- `WorkflowStarted`
- `SignalAccepted`
- `ActivationStarted`
- `ActivityScheduled`
- `ActivityLeaseAcquired`
- `ActivityCompleted`
- `ActivityFailed`
- `TimerScheduled`
- `TimerFired`
- `HumanTaskCreated`
- `HumanTaskCompleted`
- `WorkflowPaused`
- `WorkflowResumed`
- `WorkflowPatched`
- `ChildWorkflowStarted`
- `ChildWorkflowCompleted`
- `SnapshotWritten`
- `WorkflowCompleted`

Runic's own `Workflow.log/1` should be treated as a **rehydration artifact**, not the platform's authoritative audit log.

### 4.5 Timer and scheduling subsystem

Implement durable timers outside Runic:

- timer creation happens during activation when a Runic node emits a sleep/wait command
- timer rows are inserted transactionally with the instance update
- a timer scanner claims due timers and appends `TimerFired` signals
- the corresponding instance is re-queued for activation

Recommended orchestration primitives implemented as custom Runic nodes or command facts:

- `SleepUntil`
- `SleepFor`
- `AwaitSignal`
- `AwaitAnySignal`
- `AwaitHumanTask`

These should never block inside `execute/2`.

### 4.6 Signal ingestion and routing

All external inputs should enter through a durable signal inbox.

Routing flow:

1. accept API call or webhook
2. resolve target instance by instance ID or correlation key
3. insert signal row with idempotency key
4. append `SignalAccepted`
5. mark instance `RUNNABLE`
6. enqueue activation

Inside activation, translate signal rows into Runic facts or custom signal components.

### 4.7 Pause/resume mechanics

Platform-level pause/resume must be explicit.

Pause:

- append `WorkflowPaused`
- set instance status to `PAUSED`
- prevent further activation except by admin override

Resume:

- append `WorkflowResumed`
- clear pause gate
- enqueue activation

Operational wait states are different from administrative pause:

- `WAITING_TIMER`
- `WAITING_SIGNAL`
- `WAITING_HUMAN`

Those are normal dormant states, not operator pauses.

### 4.8 Worker and compute model

Use two worker classes:

- **Activation workers**: CPU-light, stateful only for the duration of a lease; run Runic and decide next commands
- **Activity workers**: execute external side effects; lease activity tasks; heartbeat; post completion/failure signals

Do not use `Runic.Runner.Worker` as the main production worker abstraction for long-lived orchestration. It is tied to the one-process-per-instance model and late durability of dispatch events.

### 4.9 Recovery and replay strategy

Recovery sequence:

1. lease instance
2. load latest snapshot
3. apply post-snapshot platform events
4. reconstruct Runic state
5. continue activation

For correctness:

- activity scheduling must be persisted before workers execute the activity
- activity completion must be deduped by `(instance_id, activity_id, attempt)`
- signal application must be idempotent
- resuming after crash must only re-run work whose durable intent exists but whose completion does not

### 4.10 Observability, auditability, and debugging

Build three views:

- **instance summary**: status, wait reason, next wake-up, pending activities, pending human tasks
- **timeline**: ordered platform event log with payloads and causation
- **graph/state view**: current Runic graph plus leaf outputs and selected internal facts

Leverage existing Runic visualization:

- Mermaid / Cytoscape serializers for graph inspection: `runic/guides/cheatsheet.md:238-254`

Add platform telemetry for:

- activation latency
- replay time
- signal lag
- timer lag
- activity retry counts
- stuck wait states
- per-definition error rates

### 4.11 APIs for querying, signaling, and controlling workflows

Recommended API surface:

- `POST /workflow-instances`
- `GET /workflow-instances/:id`
- `GET /workflow-instances/:id/history`
- `POST /workflow-instances/:id/signals`
- `POST /workflow-instances/:id/pause`
- `POST /workflow-instances/:id/resume`
- `POST /workflow-instances/:id/cancel`
- `POST /workflow-instances/:id/retry`
- `POST /workflow-instances/:id/patch`
- `GET /workflow-instances/:id/pending-activities`
- `GET /workflow-instances/:id/pending-human-tasks`
- `GET /workflow-instances/:id/graph`

### 4.12 Support for long-lived agentic steps

Agentic work should be modelled as:

- a child workflow instance, or
- a durable activity with heartbeats and incremental signals

Recommended pattern:

- parent Runic workflow emits `StartAgentSession`
- agent service owns conversation/tool loop and durable intermediate state
- agent heartbeats emit `AgentProgress` signals
- final result emits `AgentCompleted`
- parent workflow resumes on those signals

This keeps the parent dormant while the agent runs and avoids holding Runic compute open during multi-minute or multi-hour agent loops.

### 4.13 Efficient dormant execution handling

Dormant execution should be a data problem, not a process problem.

Required behavior:

- persist snapshot and wait reason
- unload instance from memory
- keep only a row and supporting timer/signal records
- wake only on due timer, signal, or operator action

This is essential for scale.


## 5. Execution model and lifecycle

### 5.1 Start

1. Client starts an instance for workflow definition `type@version`.
2. Platform appends `WorkflowStarted`.
3. Platform writes initial snapshot and marks instance `RUNNABLE`.
4. Activation worker leases the instance.

### 5.2 Activation

1. Worker loads snapshot and pending signals.
2. Worker rehydrates Runic workflow.
3. Signals are translated into facts/events meaningful to the Runic graph.
4. Worker calls `plan_eagerly/2`, `prepare_for_dispatch/1`, executes decision nodes, and applies results.
5. Worker stops when the workflow reaches a stable boundary:
   - emits external commands
   - schedules a timer
   - waits for a signal
   - pauses for human input
   - completes/fails

### 5.3 External activity dispatch

1. Activation interprets a Runic output as `ActivityScheduled`.
2. Platform appends the scheduling event and writes the activity row in the same transaction.
3. Outbox publishes work to activity workers.
4. Activity worker claims lease and executes with idempotency token.
5. Activity completion/failure is written as a signal event back to the instance.

This is where the platform fixes the current Runic durability gap: dispatch intent is durable before side effects begin.

### 5.4 Waiting and dormancy

When the workflow is waiting:

- status becomes `WAITING_SIGNAL`, `WAITING_TIMER`, or `WAITING_HUMAN`
- latest snapshot is persisted
- lease is released
- no process remains alive for the instance

### 5.5 Wake-up and resumption

On signal or timer fire:

1. inbox/timer subsystem appends a signal event
2. instance is marked `RUNNABLE`
3. activation worker rehydrates state
4. signal is injected into Runic
5. workflow continues

### 5.6 Replay after crash or redeploy

On activation worker crash:

- lease expires
- another worker replays from snapshot + event tail

On deploy:

- immutable workflow definition versions guarantee old instances keep old semantics
- new instances can start on new versions
- explicit patch/migration logic handles upgrades of running instances

### 5.7 Completion

When terminal:

- append `WorkflowCompleted`, `WorkflowFailed`, or `WorkflowCancelled`
- persist final snapshot
- close timers/activities/human tasks
- keep history queryable without any live compute


## 6. Final recommendation

Runic is suitable as the **core runtime engine inside** a durable orchestration platform, but only if we are disciplined about where its responsibility stops.

Recommendation:

- **Adopt `Runic.Workflow`, the three-phase model, and custom `Invokable` nodes as the execution kernel.**
- **Do not adopt `Runic.Runner` as the production orchestration runtime for durable, long-lived workflows.**

Concretely:

1. Use Runic for graph composition, dependency resolution, stateful node execution, and local decision-making.
2. Build a separate orchestration substrate for instance state, append-only history, timers, signals, human tasks, activity scheduling, dormancy, and query/control APIs.
3. Treat current Runic "durable execution" as a useful prototype capability, not sufficient production durability semantics.
4. Freeze workflow definitions by version and do not rely on replaying arbitrary closure AST against whatever code happens to be deployed later.
5. Require effectively-once activity semantics from the platform, not from Runic itself.

If we are willing to build that surrounding platform, Runic is a good kernel choice because its graph model and three-phase execution map well onto orchestration activations.

If we want a ready-made durable orchestration engine with built-in timers, signals, dormancy, activity leasing, and strong recovery semantics, Runic is not enough on its own and should not be used as the entire foundation.
