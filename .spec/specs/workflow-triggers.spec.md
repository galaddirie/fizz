# Workflow Triggers

This spec covers the trigger registration lifecycle, fire routing semantics,
event deduplication, compiler integration, and the behaviour composition model
that unifies trigger executors with the existing step executor system.

```spec-meta
id: workflows.triggers
kind: service
status: active
summary: Triggers are registered signal producers that create persistent external-event listeners, route incoming events through Oban for dedup and retry, and either create new workflow runs (definition-level) or deliver signals to existing runs (run-level) depending on registration scope.
surface:
  - docs/plans/triggers-design.md
  - .spec/decisions/trigger-registry-architecture.md
  - .spec/decisions/postgres-control-plane.md
  - .spec/decisions/signal-dedup-scope.md
```

## Requirements

```spec-requirements
- id: workflows.triggers.behaviour_composition
  statement: Trigger executor modules implement both `Fizz.Steps.Executors.Behaviour` (for `execute/3`, `validate_config/1`, `effective_output_schema/1`) and `Fizz.Triggers.Behaviour` (for `registration_spec/2`, `match?/2`, `normalize_event/2`). The `use Fizz.Steps.Definition, kind: :trigger` macro wires both behaviours automatically. `match?/2` is optional and defaults to returning true.
  priority: must
  stability: stable

- id: workflows.triggers.registration_spec
  statement: Each trigger executor declares a `registration_spec/2` callback that returns a `%Fizz.Triggers.RegistrationSpec{}` describing the external source it listens to. The spec includes a `kind` (one of manual, webhook, schedule, polling, subscription, chat), provider-specific `params`, and an optional `dedup_key`. This is called at publish time for definition-level registrations and at subscribe time for run-level registrations.
  priority: must
  stability: stable

- id: workflows.triggers.definition_level_registration
  statement: When a workflow definition version is published, the platform extracts a trigger manifest from the compiled workflow metadata, calls `registration_spec/2` on each trigger executor, and upserts corresponding rows in the `trigger_registrations` table with `run_id IS NULL`. These registrations are always-on while the version is published and survive deploys, node failures, and restarts because they are persisted in Postgres.
  priority: must
  stability: stable

- id: workflows.triggers.run_level_registration
  statement: A running workflow can dynamically create trigger registrations scoped to its own `run_id`. When an event matches a run-level registration, the platform delivers a signal to the existing run via the signal inbox rather than creating a new run. This unifies triggers and signals — a run-level trigger is a signal subscription with a registered external source.
  priority: should
  stability: evolving

- id: workflows.triggers.fire_routing
  statement: When a trigger fires, the routing decision depends on one field — `trigger_registrations.run_id`. If NULL, the TriggerFireWorker creates a new workflow run. If non-NULL, it delivers a signal to the existing run via the signal inbox. All trigger fires route through Oban for consistent retry, dedup, and observability.
  priority: must
  stability: stable

- id: workflows.triggers.event_dedup
  statement: Trigger event deduplication operates at three layers. First, Oban unique job constraints on `(trigger_registration_id, event_id)` prevent double-firing within a 5-minute window. Second, the `trigger_events` table provides a longer-term dedup log via a unique index on `(trigger_registration_id, event_id)`. Third, for run-level triggers, signal inbox dedup at `(run_id, signal_id)` provides the final guarantee.
  priority: must
  stability: stable

- id: workflows.triggers.registration_lifecycle
  statement: Trigger registrations follow a lifecycle with states active, paused, errored, inactive, and a transient firing state. Active registrations are eligible for event matching. Errored registrations accumulate a consecutive error count and are automatically recovered after a cooldown period by the RegistrationSyncWorker. Inactive registrations result from unpublishing or run completion. Paused registrations are operator-initiated.
  priority: must
  stability: stable

- id: workflows.triggers.compiler_integration
  statement: The compiler normalizer validates that all steps with `kind: :trigger` are graph roots (in-degree zero) and rejects trigger steps with incoming connections. The assembler extracts a `trigger_manifest` into the workflow's `fizz_metadata` containing each trigger step's `step_id`, `type_id`, and `config`. The compiler version is bumped when trigger manifest support is added.
  priority: must
  stability: stable

- id: workflows.triggers.publish_sync
  statement: When a definition version transitions to published, the platform calls `RegistrationManager.sync_on_publish/1` which reads the trigger manifest, calls `registration_spec/2` on each trigger executor, upserts registrations, and deactivates registrations from previous published versions. This is idempotent — re-publishing with the same config digest produces no duplicate registrations.
  priority: must
  stability: stable

- id: workflows.triggers.registration_sync_reconciliation
  statement: A periodic Oban cron worker (RegistrationSyncWorker) reconciles the trigger_registrations table by creating missing registrations for published versions, deactivating registrations for unpublished or archived versions, resetting errored registrations past their cooldown period, and re-enqueuing missing Oban scheduled jobs for active schedule registrations (safety net for lost job chains).
  priority: must
  stability: stable

- id: workflows.triggers.trigger_root_constraint
  statement: Trigger steps must be graph roots with in-degree zero. A workflow can have multiple trigger root nodes; each independently creates a new run when it fires (any-of semantics). Multi-condition convergence patterns belong to the signal system, not the trigger system.
  priority: must
  stability: stable

- id: workflows.triggers.scope_isolation
  statement: All trigger registrations, events, and operations are scoped through `project_id` and `workos_organization_id`, matching the rest of the platform. Trigger operations require project membership via `%Fizz.Accounts.Scope{}`. Webhook endpoints verify HMAC signatures but do not require user authentication.
  priority: must
  stability: stable
```

## Scenarios

```spec-scenarios
- id: workflows.triggers.publish_creates_registrations
  given:
    - a workflow definition version has two trigger steps (a webhook trigger and a schedule trigger)
    - the version is published
  when:
    - the publish hook calls RegistrationManager.sync_on_publish
  then:
    - two trigger_registrations rows are created with status active
    - the webhook registration has a generated webhook_path and webhook_secret
    - the schedule registration has a computed next_fire_at from the cron expression
    - the schedule registration has a corresponding Oban TriggerFireWorker job enqueued with scheduled_at set to next_fire_at
    - both registrations reference the definition version and project
  covers:
    - workflows.triggers.definition_level_registration
    - workflows.triggers.publish_sync
    - workflows.triggers.registration_spec

- id: workflows.triggers.webhook_fire_creates_run
  given:
    - a webhook trigger registration is active with run_id NULL
    - an HTTP POST arrives at the webhook URL with a valid HMAC signature
  when:
    - the webhook controller processes the request
  then:
    - the executor's match? callback returns true
    - the executor's normalize_event callback shapes the payload
    - a TriggerFireWorker job is enqueued
    - the worker creates a new workflow run with the normalized data as input
    - the run's triggered_by metadata records the registration and event details
  covers:
    - workflows.triggers.fire_routing
    - workflows.triggers.definition_level_registration
    - workflows.triggers.behaviour_composition

- id: workflows.triggers.schedule_fire_creates_run
  given:
    - a schedule trigger registration is active with a pending Oban TriggerFireWorker job scheduled for next_fire_at
    - the scheduled time arrives
  when:
    - Oban executes the TriggerFireWorker job
  then:
    - the worker creates a new workflow run with schedule metadata
    - next_fire_at is recomputed from the cron expression and updated on the registration
    - a new TriggerFireWorker job is enqueued with scheduled_at set to the new next_fire_at (self-perpetuating chain)
  covers:
    - workflows.triggers.fire_routing
    - workflows.triggers.definition_level_registration

- id: workflows.triggers.run_level_trigger_delivers_signal
  given:
    - a running workflow has created a run-level trigger registration with its own run_id
    - an event arrives matching that registration
  when:
    - the TriggerFireWorker processes the event
  then:
    - the worker delivers a signal to the existing run via the signal inbox
    - no new run is created
  covers:
    - workflows.triggers.run_level_registration
    - workflows.triggers.fire_routing

- id: workflows.triggers.event_dedup_prevents_double_fire
  given:
    - a webhook event arrives with a specific event_id
    - the same event is retried by the external provider with the same event_id
  when:
    - both events are processed
  then:
    - only one TriggerFireWorker job executes due to Oban unique constraints
    - the trigger_events table contains one row for the event_id
    - only one workflow run is created
  covers:
    - workflows.triggers.event_dedup

- id: workflows.triggers.unpublish_deactivates_registrations
  given:
    - a workflow definition version has active trigger registrations
    - a new version is published replacing the old one
  when:
    - sync_on_publish runs for the new version
  then:
    - registrations for the old version transition to inactive
    - registrations for the new version are created as active
  covers:
    - workflows.triggers.publish_sync
    - workflows.triggers.registration_lifecycle

- id: workflows.triggers.errored_registration_recovery
  given:
    - a trigger registration has accumulated consecutive errors and transitioned to errored
    - the cooldown period has elapsed
  when:
    - the RegistrationSyncWorker runs its reconciliation cycle
  then:
    - the errored registration is reset to active
    - the consecutive error count is cleared
  covers:
    - workflows.triggers.registration_lifecycle
    - workflows.triggers.registration_sync_reconciliation

- id: workflows.triggers.compiler_rejects_non_root_trigger
  given:
    - a workflow definition has a trigger step with incoming connections
  when:
    - the definition is compiled
  then:
    - the compiler normalizer returns an error indicating trigger steps must be graph roots
  covers:
    - workflows.triggers.compiler_integration
    - workflows.triggers.trigger_root_constraint

- id: workflows.triggers.trigger_manifest_extraction
  given:
    - a workflow definition has trigger steps
  when:
    - the compiler assembler processes the definition
  then:
    - the compiled workflow's fizz_metadata contains a trigger_manifest
    - each entry in the manifest includes step_id, type_id, and config
  covers:
    - workflows.triggers.compiler_integration

- id: workflows.triggers.multiple_triggers_any_of
  given:
    - a workflow has both a webhook trigger and a manual trigger as root nodes
    - the webhook trigger fires
  when:
    - the TriggerFireWorker creates a new run
  then:
    - the webhook trigger's normalized data is the initial input
    - the manual trigger root node receives no input and does not activate
    - the workflow proceeds along the webhook trigger's branch only
  covers:
    - workflows.triggers.trigger_root_constraint
    - workflows.triggers.fire_routing
```

## Verification

```spec-verification
- kind: doc_file
  target: docs/plans/triggers-design.md
  covers:
    - workflows.triggers.behaviour_composition
    - workflows.triggers.registration_spec
    - workflows.triggers.definition_level_registration
    - workflows.triggers.run_level_registration
    - workflows.triggers.fire_routing
    - workflows.triggers.event_dedup
    - workflows.triggers.registration_lifecycle
    - workflows.triggers.compiler_integration
    - workflows.triggers.publish_sync
    - workflows.triggers.registration_sync_reconciliation
    - workflows.triggers.trigger_root_constraint
    - workflows.triggers.scope_isolation
    - workflows.triggers.publish_creates_registrations
    - workflows.triggers.webhook_fire_creates_run
    - workflows.triggers.schedule_fire_creates_run
    - workflows.triggers.run_level_trigger_delivers_signal
    - workflows.triggers.event_dedup_prevents_double_fire
    - workflows.triggers.unpublish_deactivates_registrations
    - workflows.triggers.multiple_triggers_any_of

- kind: doc_file
  target: .spec/decisions/trigger-registry-architecture.md
  covers:
    - workflows.triggers.definition_level_registration
    - workflows.triggers.publish_sync
    - workflows.triggers.registration_sync_reconciliation

- kind: doc_file
  target: .spec/decisions/postgres-control-plane.md
  covers:
    - workflows.triggers.definition_level_registration
    - workflows.triggers.event_dedup
    - workflows.triggers.registration_lifecycle
    - workflows.triggers.scope_isolation
```

## Exceptions

```spec-exceptions
- id: workflows.triggers.impl_pending
  note: The repository does not yet contain trigger behaviour definitions, registration schemas, the trigger registry, fire workers, compiler trigger manifest extraction, or publish-time registration sync. The existing trigger executor stubs (manual_input, schedule_trigger, on_chat_trigger) define metadata and passthrough execute/3 but do not implement registration_spec/2 or normalize_event/2.
  relates_to:
    - workflows.triggers.behaviour_composition
    - workflows.triggers.registration_spec
    - workflows.triggers.definition_level_registration
    - workflows.triggers.fire_routing
    - workflows.triggers.event_dedup
    - workflows.triggers.compiler_integration
    - workflows.triggers.publish_sync
```
