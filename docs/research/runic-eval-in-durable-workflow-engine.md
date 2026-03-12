# Designing a Durable Workflow Orchestration System in Elixir with Runic, Postgres, and SQLite

## Runic’s execution and durability model as a kernel

Runic is explicitly designed to model “programs as data driven workflows” using a decorated dataflow graph (a DAG) with lazy evaluation and concurrency, and it supports composing and modifying workflows at runtime rather than requiring a workflow to be fully known at compile time. citeturn3view0 This is a strong starting point for a durable orchestration layer because durable workflow engines generally need: (a) an internal representation of workflow state that can be reconstructed after failure, (b) a way to coordinate concurrent execution safely, and (c) a mechanism for pausing/resuming without losing state.

Two parts of Runic particularly matter for durability and long-lived resumption:

Runic’s three-phase execution model (“prepare → execute → apply”) extracts runnable units of work that can execute without direct access to the live workflow structure, and then applies results back into the workflow. This separation is what makes it realistic to add external scheduling, remote execution, and durable checkpointing around the runtime, because the “execute” phase can be treated as an isolated activity, while “apply” becomes the single-writer state transition. citeturn3view0turn4view1turn25view3

Runic’s event-sourcing approach persists enough information to rebuild both structure and execution state. The durable-execution guide describes a “build log” plus reaction history (and optionally runnable lifecycle events) as sufficient to reconstruct a workflow, and the core `Workflow.log/1` and `Workflow.from_log/1` APIs implement this restoration path. citeturn4view0turn24view0turn24view2 Concretely, `Workflow.log/1` composes `build_log/1`, a traversal of “reaction” edges, and an accumulated list of runnable lifecycle events. citeturn24view0 The `from_log/1` reducer replays those events into a reconstructed graph, including rebuilding certain runtime-only properties that are intentionally stripped for serialization (notably `:meta_ref` edges’ `getter_fn`). citeturn24view2

Runic also provides a built-in `Runic.Runner` that already looks like a miniature workflow engine runtime: it starts a supervision tree with a `DynamicSupervisor` for workflow workers, a `Task.Supervisor` for execution isolation, a `Registry` for workflow lookup, and persistence via a pluggable `Runic.Runner.Store` behavior. citeturn3view0turn7view0turn7view1 Each worker runs as a `GenServer` that dispatches runnables to supervised tasks using `Task.Supervisor.async_nolink`, applies results back into the workflow, and checkpoints via a configurable checkpoint strategy such as `:every_cycle` or `{:every_n, n}`. citeturn8view0turn4view0

Taken together, Runic is best thought of as a **dataflow-oriented workflow virtual machine plus a reference runner**—which is exactly the “execution kernel” role you’re targeting—while leaving “platform orchestration” concerns (timers, signals, multi-node ownership, operator UI, etc.) to adjacent systems. Runic’s own docs explicitly position it as “process-agnostic” and designed to integrate into custom process topologies. citeturn3view0turn4view1

## A hybrid persistence architecture that matches Runic’s shape

Your proposed split—**Postgres for control-plane orchestration** and **SQLite for per-workflow append-only execution artifacts**—aligns well with how Runic separates: (a) the internal workflow state representation and its event log, from (b) the runtime topology and scheduling policy.

A workable mental model is:

Postgres is the authoritative system for *coordination and discoverability*: workflow registry, run metadata, ownership/leases, durable timers, signal routing, global search, and operator-facing status summaries.

SQLite is the authoritative system for *per-run deep history and reconstruction*: the workflow build log, reaction history, runnable lifecycle events, step outputs, and (optionally) captured logs/artifacts, stored as an append-only event stream with periodic snapshots/checkpoints.

Runic already records build and reaction events, and supports appending runnable lifecycle events (`%RunnableDispatched{}`, `%RunnableCompleted{}`, `%RunnableFailed{}`) when policies are executed in durable mode. citeturn4view0turn26view0turn22view0turn22view1turn22view2 Runic also provides `Workflow.pending_runnables/1` which identifies dispatched-but-unresolved work from persisted runnable lifecycle events, enabling post-crash re-dispatch. citeturn4view0turn24view3 This means a per-run SQLite database can store exactly the artifacts Runic needs to rebuild and continue.

Meanwhile, Postgres is strong for durable orchestration patterns that SQLite does not solve in a distributed system:

For multi-consumer coordination, Postgres explicitly supports the `FOR … SKIP LOCKED` pattern, and its documentation calls out its suitability for “queue-like” tables where consumers should skip locked rows to avoid contention (with the clear warning that it provides an inconsistent view by design). citeturn30view0

For low-latency wakeups and event fanout, Postgres supports `LISTEN`/`NOTIFY` for asynchronous notifications to connected sessions. citeturn27search0

For application-defined mutual exclusion beyond row locks, Postgres documents advisory lock functions (session-level and transaction-level) such as `pg_advisory_lock` and `pg_advisory_xact_lock`. citeturn29view0

Importantly, Runic’s `Runic.Runner.Store` API is deliberately abstract and only requires `save/3` and `load/2` (with optional `checkpoint/3`, `list/1`, etc.), which makes it feasible to implement a store adapter backed by SQLite (or backed by Postgres, or backed by object storage). citeturn7view1turn4view0 In other words, the hybrid persistence architecture can be built **without forking Runic**, although you may still want to extend Runic for incremental logging and compaction in advanced scenarios.

## Mapping the system cleanly onto BEAM and OTP primitives

This architecture maps naturally onto Elixir/OTP because the “durable” part of durable workflows is fundamentally about **supervised processes + durable state transitions**, which is one of the BEAM’s strengths.

Runic already demonstrates the core OTP mapping you want:

A `Runic.Runner` supervises a `Registry`, a `Task.Supervisor`, and a `DynamicSupervisor` for workflow workers. citeturn7view0 This directly matches OTP guidance that `DynamicSupervisor` is optimized for dynamically starting children on demand. citeturn31search0

Each workflow instance is a `GenServer` (`Runic.Runner.Worker`) that owns the authoritative in-memory workflow state and runs the “dispatch/apply” loop; it tracks active tasks and handles regular `{ref, result}` and `:DOWN` messages from `Task.Supervisor.async_nolink`. citeturn8view0turn31search2

Workflow discovery uses `Registry` with unique keys: Runic uses it to look up workflow processes by workflow ID, which fits Registry’s model of mapping keys to PIDs in a scalable, decentralized way. citeturn7view0turn31search1

In a production durable orchestrator, you can keep this basic topology and add control-plane services around it:

A “run coordinator” GenServer (or a small pool under a `PartitionSupervisor`) to claim ready work from Postgres (timers due, signals pending, async activities completed), using `SKIP LOCKED` to shard work across nodes safely. citeturn30view0

A “workflow activator” that either starts a new workflow worker (if not running) or routes a message to the existing worker via `Registry` (if running). This is exactly what Runic’s `Runic.Runner.lookup/2` + `GenServer.cast` pattern already does. citeturn7view0turn8view0

A “persistence writer” component, potentially implemented as a single writer process per workflow that batches SQLite writes (to avoid long write transactions), consistent with SQLite’s single-writer design. citeturn0search2

Where OTP does not “automatically” solve the problem is precisely where your design introduces durability requirements that outlive any single process: durable timers, cross-node leases/ownership, and exactly-once *progression* semantics. Those require a database-backed coordination protocol above the BEAM, even if the worker execution loop itself is a simple GenServer.

## Where you must add mechanisms beyond Runic for years-long safety

Runic provides the kernel primitives for crash recovery and resumability, but production-grade “sleep for months/years and resume safely” introduces four hard requirements that need explicit design above (or around) Runic.

Durable timers and long sleeps  
A BEAM process can schedule future messages, but timers are inherently in-memory runtime mechanisms; they will not survive a VM crash or a node being scaled down. Even the Erlang documentation for timers frames them as runtime constructs (e.g., one-shot timers exist until timeout or cancellation), not as durable schedules that survive restarts. citeturn31search3turn31search27 For month/year sleeps, the practical design is: represent “sleep” as state in the workflow log and schedule a durable wakeup in Postgres (e.g., `timers` table). At runtime, the worker should checkpoint, mark itself passivatable, and stop; later, a Postgres-driven scheduler claims due timers and resumes the workflow by loading the SQLite log and calling `Workflow.plan_eagerly/1` and dispatching newly-ready runnables. Runic already supports rebuilding state via `from_log/1` and re-planning. citeturn4view0turn24view2turn25view2

Exactly-once progression vs at-least-once execution  
Runic’s durable mode is best understood as enabling **at-least-once execution with recovery awareness**. It emits runnable lifecycle events when `emit_events: true`, including dispatched/completed/failed events. citeturn26view0turn22view0turn22view1turn22view2 The worker then appends those events into the workflow and checkpoints, and `pending_runnables/1` infers which dispatched runnables have no corresponding completion/failure event. citeturn4view0turn24view3turn8view0 This is enough to *identify* in-flight work after a crash, but it does not magically prevent a side-effectful step from running twice if execution succeeded but the completion event wasn’t persisted before the crash.

To reach “production-grade” semantics, you need an explicit contract for side effects. Many durable engines (including Elixir-native ones that position themselves as Temporal-like) emphasize persisted execution state, waiting/sleeping, and resumption. citeturn0search5turn0search12 Your orchestration layer should adopt a clear model such as: “workflow state transitions are exactly-once *with respect to the event log*, while external effects are at-least-once and must be idempotent,” plus enforce idempotency keys at the control-plane layer.

Runic provides helpful building blocks here: each runnable has a stable `id` derived from `{node.hash, fact.hash}` to support idempotency tracking, even though Runic itself doesn’t enforce global deduplication across crashes/nodes. citeturn23view2 You can lift that runnable id into Postgres tables (activities table unique on `{run_id, runnable_id}`) so that “dispatch activity” becomes a transactional claim, and “complete activity” becomes a transactional write of results, with the workflow worker only advancing after it observes a committed completion.

Deterministic replay and code evolution over long time horizons  
Runic’s durability is primarily **state reconstruction from an event log**, not “replay by re-running deterministic workflow code,” which is actually an advantage if you store step outputs/results. Runic’s `Workflow.from_log/1` rebuilds the graph and state by applying serialized events and edges, not by re-executing past steps. citeturn24view2

However, for any pending runnable that will execute in the future (months/years later), you still must care about code evolution. Runic stores components using serializable closures that include the quoted AST source and captured bindings, with additional metadata to rebuild an evaluation environment. citeturn21view0turn21view1turn24view2 That helps portability, but it does not guarantee semantic stability across deploys if a step references external module functions (e.g., `&MyMod.fun/1`) whose behavior changes. For “years-later resume,” you will want a **workflow definition versioning strategy** (store “workflow definition revision” and “activity implementation revision” in Postgres; constrain which code can execute old run versions; or provide explicit migration).

Safe passivation and rehydration  
Runic’s runner supports persisting state and resuming (`Runic.Runner.resume/2` loads a log from the store and calls `Workflow.from_log/1`). citeturn7view0turn4view0 That’s a solid baseline. But a long-lived orchestrator needs a deliberate policy for when to keep a GenServer alive vs stop it: if a workflow is waiting on a timer or signal, keep only minimal metadata in memory (or nothing), and rely on Postgres to rehydrate on demand. This is not a Runic kernel problem; it’s a control-plane policy problem.

## Is SQLite a sound per-workflow build log and execution artifact store?

SQLite can be a strong choice for a **per-workflow** append-only artifact, as long as you treat it as a single-writer log and design around distributed access constraints.

The main “soundness” argument in favor is structural:

Runic workflows already behave like event-sourced state machines: the build log captures structure (`%ComponentAdded{}`), reaction edges capture produced facts and execution history, and runnable lifecycle events capture in-flight attempt state for recovery. citeturn4view0turn24view0turn24view2turn22view0turn22view1turn22view2 A SQLite database is well-suited to storing an append-only sequence of events plus periodic snapshots, and it’s trivial to reconstruct Runic state by loading events and reducing with `Workflow.from_log/1`. citeturn24view2

The main “soundness” concerns are operational and distributed-systems related:

SQLite’s write concurrency model is fundamentally “many readers, single writer,” and in WAL mode it still allows only one writer at a time. citeturn0search2 That is typically fine for **one workflow = one owning worker process**.

WAL mode relies on a WAL-index in shared memory, so SQLite’s own documentation explicitly warns that WAL mode will not work on a network filesystem because readers must be on the same machine. citeturn0search2 This is critical for a multi-node workflow system: if you expect a workflow to fail over to another node that must open the same SQLite file over NFS/EFS/SMB, WAL-based concurrency will be problematic. If you absolutely require shared-disk failover, you must validate your filesystem semantics carefully and potentially avoid WAL mode (accepting different tradeoffs), or avoid shared filesystems entirely.

Therefore, the architecture is most robust when you choose one of these patterns:

Node-local SQLite + durable object storage replication: the active owner writes to a local SQLite DB file; upon checkpoint it uploads a new immutable version to object storage; Postgres stores the “current artifact pointer” (URI + generation). Failover downloads the latest committed artifact version. This avoids network filesystem WAL pitfalls. citeturn0search2turn30view0

SQLite as an artifact, Postgres as the source of truth for progression: Postgres stores the canonical event stream or step completion records (for exactly-once progression), while SQLite is generated/updated asynchronously for operator inspection and replay debugging. This avoids dual-write correctness risks when SQLite is treated as canonical.

Both still match your hybrid intent: Postgres does coordination and global visibility, while SQLite provides rich per-run history and reconstruction. The choice is whether SQLite is **authoritative state** or **derived artifact**.

## Bottom-line assessment and recommended design approach

This architecture can work well on Elixir/OTP, and Runic is a credible execution kernel for it, but only if you treat Runic as the **durable state machine core** and build a real **control plane** that enforces ownership, timers, signal delivery, and idempotent progression.

Why Runic is a strong kernel choice  
Runic already provides: dataflow DAG workflows; runtime composition; a three-phase model that cleanly separates “parallelizable execution” from “single-writer state application”; event-log-based restoration (`log/1` / `from_log/1`); explicit “durable execution” runnable lifecycle events; and a supervised runner with pluggable persistence. citeturn3view0turn4view0turn25view1turn24view2turn26view0turn7view0turn8view0 Those traits line up unusually well with what an orchestration layer needs from an embedded runtime.

Where the gaps are (and must be filled)  
Runic does not, by itself, solve platform orchestration requirements such as durable timers, multi-node ownership/leases, and global routing/visibility. Those are exactly the areas where Postgres (and common Postgres-backed Elixir primitives such as Oban) shine, because Postgres supports queue-like locking patterns (`SKIP LOCKED`), advisory locking, and async notifications. citeturn30view0turn29view0turn27search0turn27search3 Elixir-native durable workflow projects that target Temporal-like semantics typically lean on Postgres persistence and orchestration features for precisely these reasons. citeturn0search5turn0search12

Recommended production-ready shaping of your proposal  
If the goal is “sleep for months/years, resume safely,” the safest path is to make Postgres the arbiter of *when* and *where* a run executes, while SQLite stores *what happened* in that run:

Use Postgres to manage run lifecycle, leases, durable timers, and signal backlogs; implement leasing with row-level locks (`FOR UPDATE SKIP LOCKED`) or advisory locks for mutual exclusion; optionally use `LISTEN/NOTIFY` only as a latency optimization, not as the sole durable trigger. citeturn30view0turn29view0turn27search0

Keep a strict single-writer invariant per workflow: one owning worker process appends to the SQLite artifact and advances the canonical run state in Postgres. SQLite’s single-writer design then becomes a feature, not a limitation. citeturn0search2turn8view0

Treat workflow progression as event-sourced: every “apply” cycle produces new immutable events; checkpointing is a snapshot of a prefix of that event stream. Runic already structures state in those terms (`Workflow.log/1`, `Workflow.from_log/1`, and `append_runnable_events/2`). citeturn24view0turn24view2turn25view1

Explicitly design for idempotency and crash windows: Runic’s durable runnable events let you *detect* in-flight work after restore, but they don’t prevent duplicate side effects. citeturn4view0turn24view3turn26view0 You should enforce idempotency at the edges (external calls) and/or implement a Postgres-backed activity table with uniqueness on runnable identity (derived from `Runnable.id`). citeturn23view2

Decide early whether SQLite is authoritative across nodes. If you require cross-node failover, avoid network filesystem WAL hazards by using node-local artifacts plus immutable uploads and Postgres pointers, because SQLite WAL mode is not designed for network filesystems. citeturn0search2turn30view0

In summary: **Yes, this architecture can work well in Elixir/OTP** because (a) Runic already maps onto GenServers, DynamicSupervisors, Registries, and supervised tasks in exactly the way you would build it yourself, citeturn7view0turn8view0turn31search0turn31search1turn31search2 and (b) Postgres is a strong control-plane substrate for durable coordination patterns that are hard to do correctly with BEAM primitives alone. citeturn30view0turn29view0turn27search0 The key is to treat Runic as the **execution kernel + event-sourced state model**, while using Postgres to provide the **durable distributed scheduler** that makes “months/years later resume” a safe, routine operation.