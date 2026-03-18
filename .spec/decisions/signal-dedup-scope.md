# Signal Dedup Scope

Status: accepted

## Context

The earlier design material left open whether `signal_id` should be globally
unique across all workflow runs or scoped to a run, and it also suggested using
workflow graph fact equality as a second-layer dedup mechanism.

Global uniqueness is unnecessary burden for callers, and payload equality is too
coarse because identical payloads can represent legitimately distinct signals.

## Decision

Signal idempotency is scoped to `(run_id, signal_id)`.

The durable dedup contract is:

- duplicate submissions with the same run id and signal id are the same logical
  signal
- the inbox uniqueness and delivery state are authoritative for idempotency
- identical payloads or signal names with different signal ids remain distinct
  signals
- workflow graph state may assist recovery or inspection but is not the primary
  API-level dedup contract

## Consequences

- Callers only need signal ids to be unique per target run.
- Distinct but identical-looking events are preserved when they carry distinct
  signal ids.
- Inbox schema and APIs should model dedup as a per-run uniqueness boundary.

## Sources

- `docs/plans/durable-workflow-system-design.md`
