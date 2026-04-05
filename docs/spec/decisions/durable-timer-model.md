# Durable Timer Model

Status: accepted

## Context

Workflow executions need to sleep for arbitrary durations, schedule future
wake-ups, and enforce activity deadlines. These timer semantics split across two
layers with different durability guarantees:

- Runic already provides in-process execution policies through `SchedulerPolicy`
  and `PolicyDriver`: per-runnable `timeout_ms`, `deadline_ms`, retry with
  configurable backoff (`:linear`, `:exponential`, `:jitter`), and
  `execution_mode: :durable` for event-sourced lifecycle tracking. These
  primitives operate within a running Worker process and do not survive
  passivation or node death.

- The platform needs durable timers that outlive any single process or node:
  `sleep(duration)` and `schedule_at(datetime)` for workflow-level waits, plus
  cron-style schedule triggers for recurring workflow starts.

## Decision

Durable timers are a platform-level concern persisted in the Postgres control
plane, not an extension of Runic's in-process scheduling primitives.

The timer contract is:

- when a workflow step produces a timer intent (`sleep` or `schedule_at`), the
  platform persists a `durable_timers` row in Postgres with a `fire_at`
  timestamp before the Worker passivates
- the control plane polls for due timers and delivers a `TimerFired` event as
  regular workflow input upon wake-up
- Runic's `SchedulerPolicy` remains the mechanism for in-process concerns:
  activity timeouts, retry backoff, deadline enforcement, and execution mode
  selection — these do not produce durable timer rows
- the boundary between in-process and durable is explicit: if the timer must
  survive Worker shutdown, it must be persisted to the control plane

Timer polling uses `FOR UPDATE SKIP LOCKED` to allow concurrent pollers without
contention. The poller transitions timers to `FIRING` atomically before waking
the target execution.

Timer states are: `PENDING`, `FIRING`, `FIRED`, `CANCELLED`.

## Consequences

- Workflows can sleep for seconds or months with the same mechanism; short
  timers may keep the Worker hot while long timers trigger passivation.
- Timer durability is independent of Worker liveness — a node crash does not
  lose pending timers.
- Runic's `SchedulerPolicy` and `PolicyDriver` continue to own retry, backoff,
  timeout, and deadline semantics within a running Worker without platform
  involvement.
- The `wait` step's current `Process.sleep` implementation is a non-durable
  placeholder; the durable path replaces it with timer-fact production,
  checkpoint, and passivation.
- Poll interval tuning, pre-warming optimizations, and passivation tier
  thresholds are operational detail and are not part of this decision.

## Related decisions

- `postgres-control-plane.md` — the durable home of the `durable_timers` table
- `per-execution-sqlite-store.md` — the execution store that checkpoints before
  the Worker passivates on a long timer
- `single-writer-leasing-and-fencing.md` — the ownership model used when waking
  an execution for a fired timer
- `runic-as-execution-kernel.md` — the kernel whose `SchedulerPolicy` owns
  in-process timeout and retry, complementing platform-level durable timers

## Sources

- `docs/plans/durable-workflow-system-design.md`
- `docs/plans/runic-research.md`
- `deps/runic/lib/workflow/scheduler_policy.ex`
- `deps/runic/lib/workflow/policy_driver.ex`
