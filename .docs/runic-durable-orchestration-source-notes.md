# Runic Durable Orchestration Source Notes

Assessed on March 6, 2026 against the local `runic/` snapshot in this workspace.

## Scope

Reviewed:
- `runic/mix.exs`
- `runic/guides/durable-execution.md`
- `runic/guides/scheduling.md`
- `runic/lib/runic/runner.ex`
- `runic/lib/runic/runner/worker.ex`
- `runic/lib/runic/runner/store.ex`
- `runic/lib/runic/runner/store/ets.ex`
- `runic/lib/runic/runner/store/mnesia.ex`
- `runic/lib/workflow.ex`
- `runic/lib/workflow/policy_driver.ex`
- `runic/lib/workflow/join.ex`
- `runic/lib/workflow/fan_in.ex`
- `runic/lib/closure.ex`
- `runic/lib/workflow/events/serializer.ex`

Validated with:
- `mix test test/runner/durable_execution_test.exs test/workflow/rehydration_test.exs test/workflow/event_sourced_test.exs test/runner/store_mnesia_test.exs`
- Result: 124 tests, 0 failures
- `mix test test/parallel_workflow_test.exs test/workflow/fan_out_join_dispatch_test.exs test/runner/worker_concurrency_test.exs test/runner/flow_batch_test.exs test/runner/gen_stage_executor_test.exs`
- Result: 51 tests, 0 failures

## Verified strengths

### Three-phase execution is real

Runic cleanly separates prepare, execute, and apply.

Evidence:
- `runic/guides/durable-execution.md:18-23`
- `runic/lib/workflow/policy_driver.ex:25-49`

Why it matters:
- This is the right foundation for a control plane that wants to externalize execution and replay state transitions later.

### Replay and rehydration are real features

Runic can rebuild workflow structure and runtime state from event history.

Evidence:
- `runic/lib/workflow.ex:996-1123`
- `runic/lib/runic/runner.ex:180-250`
- `runic/lib/workflow/rehydration.ex:113-199`

Why it matters:
- Replay is strong enough to serve as the basis for activation-time reconstruction.

### Scheduler and executor extension points are real

The runner can swap scheduler and executor strategies.

Evidence:
- `runic/lib/runic/runner/executor.ex:1-64`
- `runic/lib/runic/runner/scheduler.ex:1-77`
- `runic/lib/runic/runner/scheduler/flow_batch.ex:1-209`
- `runic/lib/runic/runner/scheduler/adaptive.ex:1-257`

Why it matters:
- Runic is flexible enough to be embedded inside a broader orchestration architecture.

### Coordination primitives are substantial inside one workflow instance

Runic has explicit support for joins, fan-out, fan-in, reduce, and promise-based dispatch grouping.

Evidence:
- `runic/lib/workflow/join.ex:18-89`
- `runic/lib/workflow/fan_in.ex:23-102`
- `runic/lib/runic/runner/promise_builder.ex:43-179`
- `runic/lib/runic/runner/scheduler/flow_batch.ex:35-209`

Why it matters:
- The library is strong at intra-instance coordination and can serve as the execution kernel for complex local graph behavior.

### Workflow closures are serializable inside an Elixir-native system

Runic explicitly models serializable closures and closure metadata.

Evidence:
- `runic/lib/closure.ex:1-214`
- `runic/lib/closure_metadata.ex:1-106`
- `runic/lib/workflow/component_added.ex:1-27`

Why it matters:
- Definition persistence is more advanced than naive anonymous-function storage.

### Runic is dataflow-driven, not time-driven

The orchestration model is based on fact availability and dispatch grouping, not on durable timers or scheduled wake-up primitives.

Evidence:
- retry backoff sleeps in `runic/lib/workflow/policy_driver.ex:69-71` and `runic/lib/workflow/policy_driver.ex:116-118`
- deadline conversion in `runic/lib/workflow.ex:2501-2511`
- deadline enforcement in `runic/lib/workflow/policy_driver.ex:210-259`
- scheduler contract in `runic/lib/runic/runner/scheduler.ex:3-63`

Why it matters:
- This is an execution-kernel design, not a full dormant-workflow timing model.

## Verified gaps and risks

### Apply remains a serialized coordination point

Execution can happen concurrently, but workflow state application is serialized through the worker.

Evidence:
- `runic/lib/runic/runner/worker.ex:502-573`
- `runic/lib/workflow.ex:3232-3265`

Impact:
- Hot workflows still funnel through one in-memory coordinator even when many tasks execute in parallel.

### Dormant workflows stay resident as workers

When a worker goes idle, it persists and flips status to `:idle`, but it does not unload itself.

Evidence:
- `runic/lib/runic/runner/worker.ex:1072-1078`

Impact:
- This is incompatible with millions of dormant workflows or very long waits.

### `resume/3` is explicit and replay is full-stream in memory

`Runic.Runner.resume/3` loads the whole event stream with `Enum.to_list/1`.

Evidence:
- `runic/lib/runic/runner.ex:180-190`

Impact:
- Recovery cost grows with history size.
- Resume is not an automatic cluster-wide ownership recovery system.

### Snapshot callbacks exist in the store behaviour, but are not used

The store behaviour advertises snapshot support, but the current code path does not consume it.

Evidence:
- `runic/lib/runic/runner/store.ex:24-31`
- no `save_snapshot/4` or `load_snapshot/2` implementations in `runic/lib/`

Impact:
- The runtime has replay machinery, but not a full snapshot-accelerated recovery loop yet.

### Durable in-flight recovery has a crash window

Runnable lifecycle events are generated during execution, but persistence happens after the runnable result is handled.

Evidence:
- dispatched/completed events built in `runic/lib/workflow/policy_driver.ex:97-160`
- persistence buffering happens in `runic/lib/runic/runner/worker.ex:502-573`

Impact:
- If a side-effectful step executes and the process dies before the durable events are appended, replay may rerun it.
- This means the current system is not exactly-once for side effects.

### Persistence acknowledgement is too weak

The worker clears buffered events after `append/3` and does not require a success value in the steady-state checkpoint and save paths.

Evidence:
- `runic/lib/runic/runner/worker.ex:1231-1241`
- `runic/lib/runic/runner/worker.ex:1279-1288`
- fact writes ignore return values in `runic/lib/runic/runner/worker.ex:1199-1205`

Impact:
- A production durability layer should treat append failure as a state transition failure, not as a best-effort side effect.

### There is no first-class timer, signal, or human wait primitive

The guides talk about approval workflows, but the runtime does not provide durable timer registration, signal inboxes, or human task abstractions.

Evidence:
- guide language in `runic/guides/durable-execution.md:14-16`
- manual checkpoint example in `runic/guides/durable-execution.md:387-399`
- no timer or signal wait API in `runic/lib/runic/runner.ex`

Impact:
- These capabilities must be built outside Runic if the platform is meant to support true dormant workflows.

### Synchronization waits exist, but they are graph-local coordination waits

Join and fan-in can wait for missing upstream facts, but this is not the same thing as a durable suspended workflow state with a wake-up contract.

Evidence:
- join coordination in `runic/lib/workflow/invokable.ex:1257-1304`
- fan-in coordination in `runic/lib/workflow/invokable.ex:1786-1798`
- runnable status shape in `runic/lib/workflow/runnable.ex:23-30`

Impact:
- Runic can express "this node is waiting on more graph input," but not "this workflow is durably waiting on a timer, signal, human task, or child workflow" as a first-class runtime abstraction.

### Parent/child workflow orchestration is not a runtime feature

Workflow composition exists, but it is graph flattening rather than inter-instance parent/child orchestration.

Evidence:
- `runic/lib/workflow.ex:1913-1933`
- `runic/lib/workflow/component.ex:1222-1311`
- `runic/lib/runic/runner.ex:66-79`

Impact:
- The control plane must own child-workflow lifecycle, parent waiting, and cancellation propagation.

### Mnesia is functional, but not a strong control-plane database choice

Mnesia provides transactional append and optional disk copies, but the implementation uses dirty reads for log access and is tightly coupled to OTP cluster behavior.

Evidence:
- `runic/lib/runic/runner/store/mnesia.ex:38-52`
- `runic/lib/runic/runner/store/mnesia.ex:103-155`

Impact:
- Mnesia is serviceable as an OTP-native store, but not the storage system I would choose for a multi-tenant orchestration control plane with rich APIs and audit needs.

### Event serialization is BEAM-native, not system-neutral

Runic events serialize naturally via ETF and the docs explicitly call out that this format is tied to Erlang terms and struct modules.

Evidence:
- `runic/lib/workflow/events/serializer.ex:3-39`

Impact:
- Definition and event versioning need stronger platform-level discipline across releases.

### Join and fan-in replay need scrutiny around downstream activation

Join and fan-in coordinators activate downstream steps in memory after emitting their completion events.

Evidence:
- `runic/lib/workflow/join.ex:81-89`
- `runic/lib/workflow/fan_in.ex:89-102`
- replay of completion events in `runic/lib/workflow.ex:777-842`
- activation protocol expectation in `runic/lib/workflow/activator.ex:18-23`

Impact:
- Replay correctness across coordination boundaries should be treated carefully if the platform leans heavily on those constructs for durable orchestration.

### Policy fields are ahead of the runtime in some places

`SchedulerPolicy` includes `idempotency_key`, `deadline_ms`, and `circuit_breaker`.

Evidence:
- `runic/lib/workflow/scheduler_policy.ex:62-116`
- event stripping of `idempotency_key` in `runic/lib/workflow/policy_driver.ex:202-204`

Observed state:
- workflow-level deadline support is real in `runic/lib/workflow.ex:2459-2515`
- `idempotency_key` is not enforced as a durable command protocol
- `circuit_breaker` does not appear to have a concrete runner implementation in the reviewed paths

Impact:
- The orchestration platform should not assume these fields already provide production semantics.

### Promise batching changes scaling behavior in ways the control plane should not inherit blindly

Parallel promises consume one worker slot regardless of how many runnables they contain, and promise coverage is tracked by node hash rather than full runnable id.

Evidence:
- `runic/lib/runic/runner/worker.ex:587-600`
- `runic/lib/runic/runner/worker.ex:618-779`
- `runic/lib/runic/runner/promise.ex:61-67`
- `runic/lib/workflow/runnable.ex:52-58`

Impact:
- Large admitted batches can bypass normal per-runnable worker limits.
- Coverage by node hash can suppress cross-input parallelism for the same node shape.
- These are acceptable execution-kernel tradeoffs, but they are not a durable orchestration admission-control model.

## Architectural implications

What this means in practice:
- Use Runic for replayable state transitions.
- Do not use the current `Runic.Runner` worker lifecycle as the long-lived dormant execution model.
- Put Postgres, leases, event append, timers, signals, activities, and query projections around it.
- Treat all external side effects as activity commands, not as arbitrary opaque step closures.
- Keep workflow definitions immutable and versioned.

## Bottom line

Runic already contains enough of a deterministic workflow kernel to justify building on it.

It does not yet contain the durable orchestration substrate you need for:
- long inactivity
- event-driven resumption
- human approval pauses
- dormant execution eviction
- activity correctness boundaries
- inter-instance orchestration

That substrate needs to be built around Runic, not assumed from the current runner.
