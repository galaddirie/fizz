# Trigger Registry Architecture

Status: accepted

## Context

The trigger system needs a lookup mechanism to route incoming events to the
correct trigger registration. Webhook requests must be routed by path token in
sub-millisecond time. Schedule and polling triggers need enumeration by kind.
The source of truth for registrations is the Postgres `trigger_registrations`
table, but hitting Postgres on every webhook request is unacceptable for
latency.

The platform already has `Fizz.Steps.Registry` — an ETS-backed GenServer that
caches step type definitions for fast lookup. The trigger registration cache
follows the same pattern but serves a different purpose: step types are static
(loaded at boot), while trigger registrations are dynamic (created/updated at
publish time, deactivated on unpublish).

## Decision

The trigger registration cache is an ETS-backed GenServer
(`Fizz.Triggers.Registry`) that loads active `trigger_registrations` rows from
Postgres into ETS on initialization and keeps them synchronized via PG
LISTEN/NOTIFY with periodic full-refresh as a fallback.

The registry:

- loads all active registrations from Postgres into ETS on init, indexed by
  `webhook_path`, `project_id`, and `kind`
- subscribes to a `trigger_registrations` Postgres LISTEN/NOTIFY channel for
  real-time updates when registrations are created, updated, or deactivated
- performs a periodic full refresh (every 60 seconds) as a catch-up mechanism
  for missed LISTEN/NOTIFY notifications (connection drops, PG failover)
- provides lookup APIs: `get_by_webhook_path/1` (~1 microsecond ETS lookup),
  `list_by_kind/2`, `list_by_project/1`
- is a separate process from `Fizz.Steps.Registry` — they serve different
  concerns with different update characteristics

## Consequences

- Webhook routing is sub-millisecond: the `WebhookController` does a single ETS
  lookup by `webhook_path` token, avoiding a Postgres round-trip on every
  request.
- Registration changes propagate to all nodes within seconds via LISTEN/NOTIFY,
  with a guaranteed 60-second maximum staleness from the periodic refresh.
- The LISTEN/NOTIFY connection can drop (PG failover, network partition). The
  registry must handle reconnection gracefully and rely on periodic refresh as
  the authoritative catch-up path. Oban's `Oban.Notifiers.Postgres` in the
  existing codebase provides a reference pattern for reconnection handling.
- ETS memory scales linearly with active registrations. At thousands of
  registrations per project, this is negligible.
- The registry is a read-optimized cache. All mutations go through the
  `Fizz.Triggers` context module which writes to Postgres and triggers the
  LISTEN/NOTIFY notification.

## Related decisions

- `postgres-control-plane.md` — the `trigger_registrations` table that this
  cache fronts
- `signal-dedup-scope.md` — run-level trigger registrations deliver signals
  through the same inbox

## Sources

- `docs/plans/triggers-design.md`
- `lib/fizz/steps/registry.ex` — existing ETS-backed step type registry pattern
