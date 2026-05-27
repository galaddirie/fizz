# Integration Refactor Handoff

Status date: 2026-05-27

This is the current handoff point for the metadata-first integration refactor. The
dynamic field resolver work and the credential/slot cleanup are now committed.

## Executive Summary

- Branch: `refactor/v0.2.0`
- Phase 0-4 checkpoint: `8931099 feat(integrations): add metadata-first catalog foundation`
- Phase 5 checkpoint: `9ef8cfd refactor: add resource locator/mapper field support`
- Credential field checkpoint: `d824f3d Replace slot bindings with credential bindings`
- Operation metadata checkpoint: `4944cce Refactor Google Sheets operations & credential UI`
- Current committed scope: Phases 0 through 5 plus the credential field ownership cleanup and Google Sheets operation metadata ownership
- Current uncommitted scope: normalized operation errors, Google Sheets client error normalization, retry policy metadata, and shared `Fizz.Fields` ownership for operation/credential fields
- Recommended next slice after this diff: runner persistence/resume design for durable operation retries

## What Changed Since The Previous Handoff

### Phase 5 - Dynamic UI Resolver Layer

Phase 5 is committed in `9ef8cfd`.

- Added `Fizz.Integrations.DynamicResolver`.
- Replaced editor-specific resolver inspection with `DynamicResolver.resolve/4`.
- Added schema metadata support for `depends_on`, `display`, `resource_locator`, and
  `resource_mapper`.
- Renamed the Google Sheets-specific mapper surface from `MapEditor.vue` to the generic
  `ResourceMapperField.vue`.
- Moved mapper labels, lookup fields, and async error copy into schema/resolver metadata.
- Preserved schema-owned resolver params over client payload params.

Validation completed for Phase 5:

```sh
mix test test/fizz/integrations/dynamic_resolver_test.exs test/fizz/integrations/catalog_validation_test.exs test/fizz_web/live/workflow_editor_live_test.exs
mix test
mix assets.build
mix precommit
```

### Credential Field Ownership Cleanup

The credential/slot cleanup is committed in `d824f3d`.

- Deleted the generic `Fizz.Slots` context, registry, resolver behavior, credential slot
  wrapper, and slot binding schema.
- Deleted `Fizz.Steps.Resolver`; edit-time dynamic values now go through
  `Fizz.Integrations.DynamicResolver`.
- Added first-class credential declaration, field, requirement, binding, defaults, option
  lookup, and option resolver modules under `Fizz.Credentials`.
- Replaced `$slot` runtime access plans with explicit credential access plans.
- Replaced `Fizz.Workflows.SlotBinding` with `Fizz.Workflows.CredentialBinding`.
- Replaced the old `slot_bindings` table with `credential_bindings`; no data migration
  was needed because there is no real user data.
- Replaced `RunLaunchModal.vue` and `SlotField.vue` with credential-named Vue components.
- Updated workflow readiness, publish validation, trigger registration, compiler, runtime
  config resolution, and editor events to speak credential bindings directly.

Validation completed for the credential cleanup:

```sh
mix compile
mix test test/fizz/credentials_test.exs test/fizz/credentials/workos_oauth_autobind_test.exs test/fizz/credentials/options_resolver_test.exs test/fizz/steps/credential_field_test.exs test/fizz/integrations/catalog_guardrails_test.exs test/fizz/workflows/compiler_test.exs test/fizz/workflows/draft_validator_test.exs test/fizz/workflows/runtime/context_builder_test.exs test/fizz/workflows/compiler/assembler_context_test.exs test/fizz/workflows_test.exs test/fizz_web/live/workflow_editor_live_test.exs test/fizz/triggers/registration_manager_test.exs test/fizz/triggers/basic_triggers_integration_test.exs test/fizz_web/controllers/triggers/webhook_controller_test.exs
mix precommit
mix assets.deploy
```

`mix precommit` passed with `503 tests, 0 failures`. `mix assets.deploy` passed with the
same existing third-party Vite/Tailwind warnings seen before.

### Operation Metadata Ownership

This slice is committed in `4944cce`.

- Google Sheets append-row/read-rows operation modules now own their
  `OperationDefinition` metadata directly.
- `Fizz.Integrations.Manifest.operation_definitions/0` consumes operation definitions
  from the operation modules instead of deriving them from step wrapper executors.
- Deleted the old Google Sheets step wrapper executor modules.
- `OperationExecutor` now dispatches operation modules with a typed
  `%Fizz.Workflows.ExecutionContext{}`.
- Google Sheets client functions accept either the typed context or the legacy map shape.

Validation completed so far:

```sh
mix compile
mix test test/fizz/integrations/catalog_validation_test.exs test/fizz/integrations/catalog_test.exs test/fizz/integrations/manifest_task_test.exs test/fizz/steps/registry_operation_definitions_test.exs test/fizz/integrations/google/sheets/actions/append_row_test.exs test/fizz/integrations/google/sheets/client_test.exs test/fizz/integrations/operation_executor_test.exs
mix assets.build
mix precommit
```

`mix precommit` passed with `503 tests, 0 failures`. `mix assets.build` passed with the
same existing third-party Vite/Tailwind warnings.

### Current Uncommitted Slice - Shared Fields, Operation Errors, And Retry Metadata

This slice continues Phase 6 and removes the remaining credential-specific field/schema
path:

- Added `Fizz.Fields` as the public field API and `Fizz.Fields.Definition` as the
  canonical typed field struct.
- JSON Schema plus per-field `"ui"` metadata is now adapter output from `Fizz.Fields`,
  not the source of truth for migrated definitions.
- Added `Fizz.Fields.Credential` as the credential field handler. It owns credential
  declaration maps, option lookup, readiness descriptors, auto-binding, runtime binding
  lookup, and API-key secret extraction.
- Deleted the dedicated credential declaration/schema modules:
  `Fizz.Credentials`, `Fizz.Credentials.Field`, `Fizz.Credentials.Requirement`,
  `Fizz.Credentials.OptionsResolver`, `Fizz.Integrations.CredentialSchema`,
  `Fizz.Integrations.CredentialRequirement`, and
  `Fizz.Integrations.Definition.Credential`.
- Removed the credential catalog kind. Provider definitions now expose
  `credential_fields`, and operation definitions expose typed `fields`.
- Google Sheets append/read operation definitions now use `fields` as the source of
  truth for credential, resource locator, and resource mapper schema metadata.
- Legacy executor modules still emit JSON Schema, but credential field construction now
  goes through `Fizz.Fields.credential/2`, `Fizz.Fields.default_value/1`, and
  `Fizz.Fields.to_schema_property/1`.

The same uncommitted slice also continues operation-error work:

- Added `Fizz.Integrations.OperationError` as the normalized runtime operation error
  shape.
- Added richer `Fizz.Integrations.RetryPolicy` metadata: max attempts, backoff kind,
  initial/max delay, and retryable categories/codes.
- `OperationExecutor` normalizes raw operation module failures before returning them to
  the workflow runner.
- Google Sheets client failures now return `OperationError` for validation, credential,
  HTTP rate-limit, transient provider, and transport/network failures.
- Google Sheets operation definitions publish retry metadata for rate-limit, network,
  and transient provider failures.
- Google Sheets field resolvers still return UI-friendly field error codes while reading
  the normalized operation error shape.

Validation completed so far:

```sh
mix test test/fizz/integrations/catalog_test.exs test/fizz/integrations/catalog_validation_test.exs test/fizz/integrations/operation_executor_test.exs test/fizz/integrations/google/sheets/actions/append_row_test.exs test/fizz/integrations/google/sheets/client_test.exs test/fizz/integrations/google/sheets/columns_resolver_test.exs test/fizz/integrations/operation_error_test.exs test/fizz/integrations/retry_policy_test.exs
mix test test/fizz/fields_test.exs test/fizz/fields/credential_test.exs test/fizz/fields/credential_options_test.exs test/fizz/fields/credential_secret_test.exs test/fizz/fields/credential_workos_oauth_autobind_test.exs test/fizz/integrations/catalog_test.exs test/fizz/integrations/catalog_validation_test.exs test/fizz/integrations/dynamic_resolver_test.exs test/fizz/integrations/google/sheets/actions/append_row_test.exs test/fizz/integrations/google/sheets/columns_resolver_test.exs test/fizz/steps/credential_field_test.exs test/fizz/steps/registry_operation_definitions_test.exs test/fizz/workflows/compiler_test.exs test/fizz/workflows/runtime/context_builder_test.exs test/fizz/workflows/draft_validator_test.exs test/fizz/triggers/registration_manager_test.exs test/fizz/triggers/basic_triggers_integration_test.exs test/fizz_web/controllers/triggers/webhook_controller_test.exs
```

## Current Architecture Decisions

### Slots

Generic runtime slots are gone. The old `$slot` abstraction was too general for the one
real use case it had: user credential choice. It created a registry, declarations,
runtime resolver behavior, and binding table without a second concrete kind.

The remaining word "slot" should only mean normal workflow graph input/output positions
or Phoenix/Vue template slots. It should not describe credential fields, credential
bindings, or runtime secret resolution.

### Credentials And Fields

Credentials are runtime auth primitives and a field type, not a parallel schema system.
Field declaration/rendering belongs to `Fizz.Fields`; provider/auth runtime behavior
belongs to provider/auth modules.

- Step config stores a credential declaration map:

  ```elixir
  %{
    "$credential" => true,
    "requirement_key" => "auth",
    "provider" => "google_oauth",
    "auth_type" => "oauth"
  }
  ```

- Field schema declares credential rendering metadata:

  ```elixir
  "ui" => %{
    "component" => "credential",
    "requirement_key" => "auth",
    "provider" => "google_oauth",
    "auth_type" => "oauth"
  }
  ```

- Per-user runtime choices live in `credential_bindings`.
- Runtime resolution produces the existing `credential_ref` map expected by auth helpers.
- Token and vault I/O still belong to `Fizz.Integrations.resolve_auth_for_execution/4`
  and provider-specific auth helpers, not to field option resolution.
- Provider credential creation forms are declared as `provider.credential_fields`, using
  the same `Fizz.Fields.Definition` structs as operation fields.
- Credential catalog entries, credential `config_schema`, and credential `ui_schema` are
  gone.

### Resolver Concepts

Keep these concepts separate:

- `Fizz.Integrations.DynamicResolver`: edit-time dispatcher for schema-declared dynamic
  field values, including selects, search fields, credential options, resource locators,
  and resource mappers.
- Resolver modules with `resolve/1`: concrete edit-time field resolvers, such as
  `Fizz.Fields.Credential` and Google Sheets resource resolvers.
- `Fizz.Fields.Credential.runtime_resolver/2`: run-time credential binding lookup that
  returns a function used by compiled access plans.
- `Fizz.Integrations.resolve_auth_for_execution/4`: run-time auth material resolution
  for API key, OAuth, and provider-specific credential backends.

Do not reintroduce a second generic resolver behavior named close to `Steps.Resolver` or
`Slots.Resolver`.

### Field State

Server-owned field state now flows through resolver replies:

- schema metadata declares dependencies, mapper lookups, and error copy
- `DynamicResolver` returns `options` plus `meta`
- Vue field components own transient loading flags only for the active request
- provider-specific async error strings should come from schema/resolver metadata, not
  hardcoded component branches

There is not yet a durable server-side field-state process. Add one only if we need to
share async field state across clients or survive reconnects; for now LiveView reply
callbacks are enough.

### JSON Schema Plus `ui`

Keep the JSON Schema plus `ui` extension pattern, but treat it as a validated Fizz
contract rather than free-form UI hints.

Reasons to keep it:

- the editor already consumes JSON-like schemas directly
- operation definitions can publish the same shape to Vue without translation
- resource mapper and locator metadata maps cleanly to n8n's field-description model
- it keeps frontend dispatch generic while server structs own construction and validation

Rules going forward:

- build credential fields with `Fizz.Fields.credential/2`
- avoid manually duplicating credential metadata in `@default_config` and `@config_schema`
- put rendering metadata on `Fizz.Fields.Definition` values and let
  `Fizz.Fields.to_schema/1` write `"ui"` adapter metadata
- validate supported components and resolver metadata at catalog/step registration time

## Remaining Work

### Phase 6 - Execution Semantics

The first two non-durable slices have started: operation modules now receive typed
execution context through `OperationExecutor`, and operation failures are being
normalized before durable retry handling exists.

Recommended order:

1. Finish any remaining Google Sheets action-level error normalization gaps.
2. Decide how retryable `OperationError` values are persisted on workflow runs.
3. Add runner resume/backoff handling.
4. Only after that, move durable retries into Oban or the existing runnable worker model.

Likely files:

- `lib/fizz/fields.ex`
- `lib/fizz/fields/definition.ex`
- `lib/fizz/fields/credential.ex`
- `lib/fizz/workflows/execution_context.ex`
- `lib/fizz/integrations/operation.ex`
- `lib/fizz/integrations/operation_executor.ex`
- `lib/fizz/integrations/operation_error.ex`
- `lib/fizz/integrations/retry_policy.ex`
- `lib/fizz/integrations/operation_definition.ex`
- `lib/fizz/integrations/definition.ex`
- `lib/fizz/integrations/manifest.ex`
- `lib/fizz/integrations/google/sheets/actions/append_row.ex`
- `lib/fizz/integrations/google/sheets/actions/read_rows.ex`
- `lib/fizz/integrations/google/sheets/client.ex`

Likely tests:

- `test/fizz/fields_test.exs`
- `test/fizz/fields/credential_test.exs`
- `test/fizz/fields/credential_options_test.exs`
- `test/fizz/workflows/execution_context_test.exs`
- `test/fizz/integrations/operation_executor_test.exs`
- `test/fizz/integrations/operation_error_test.exs`
- `test/fizz/integrations/retry_policy_test.exs`
- `test/fizz/integrations/catalog_validation_test.exs`
- `test/fizz/integrations/google/sheets/client_test.exs`

### Phase 7 - Testing Harness And Scaffolding

- Add an integration test harness with workflow fixtures, pinned outputs, credential
  fixtures, `Req.Test` expectations, and direct operation execution.
- Colocate integration fixtures beside integration modules.
- Add `mix fizz.gen.integration <provider>.<resource>`.
- Replace brittle tests that rely on `Process.sleep`.
- Remove `:sys.replace_state/2` test hacks where possible.
- Deduplicate raw SQL lease setup.

## Quality Scan Notes

`bash ~/.codex/scripts/elixir-phoenix-guide/run_analysis.sh` currently reports broad
pre-existing duplication and unused-private-function noise across the app. Relevant
follow-up items from the refactor area:

- provider modules still duplicate OAuth/API-key definition boilerplate
- `WorkflowEditorLive` and payload/revision helpers still duplicate encoding helpers
- the analyzer reports false positives for private predicate functions ending in `?`

Do not treat the scan as blocking for Phase 6, but use it to choose cleanup slices between
behavioral refactor PRs.
