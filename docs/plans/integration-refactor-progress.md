# Integration Refactor Handoff

Status date: 2026-05-27

This is the current handoff point for the metadata-first integration refactor. The
dynamic field resolver work and the credential/slot cleanup are now committed.

## Executive Summary

- Branch: `refactor/v0.2.0`
- Phase 0-4 checkpoint: `8931099 feat(integrations): add metadata-first catalog foundation`
- Phase 5 checkpoint: `9ef8cfd refactor: add resource locator/mapper field support`
- Credential field checkpoint: `d824f3d Replace slot bindings with credential bindings`
- Current committed scope: Phases 0 through 5 plus the credential field ownership cleanup
- Current uncommitted scope: Google Sheets operation metadata ownership and typed operation dispatch
- Recommended next slice after this diff: normalized operation error structs and retry metadata

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

### Current Uncommitted Slice - Operation Metadata Ownership

This slice continues the no-shim cleanup:

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

## Current Architecture Decisions

### Slots

Generic runtime slots are gone. The old `$slot` abstraction was too general for the one
real use case it had: user credential choice. It created a registry, declarations,
runtime resolver behavior, and binding table without a second concrete kind.

The remaining word "slot" should only mean normal workflow graph input/output positions
or Phoenix/Vue template slots. It should not describe credential fields, credential
bindings, or runtime secret resolution.

### Credentials

Credentials are first-class integration primitives.

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

### Resolver Concepts

Keep these concepts separate:

- `Fizz.Integrations.DynamicResolver`: edit-time dispatcher for schema-declared dynamic
  field values, including selects, search fields, credential options, resource locators,
  and resource mappers.
- Resolver modules with `resolve/1`: concrete edit-time field resolvers, such as
  `Fizz.Credentials.OptionsResolver` and Google Sheets resource resolvers.
- `Fizz.Credentials.runtime_resolver/2`: run-time credential binding lookup that returns
  a function used by compiled access plans.
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

- build credential fields with `Fizz.Credentials.Requirement` or `Fizz.Credentials.Field`
- avoid manually duplicating credential metadata in `@default_config` and `@config_schema`
- put rendering metadata under `"ui"` and persisted declaration values under config
- validate supported components and resolver metadata at catalog/step registration time

## Remaining Work

### Phase 6 - Execution Semantics

The first non-durable slice has started: operation modules now receive typed execution
context through `OperationExecutor`. Continue with error and retry normalization before
designing durable retries.

Recommended order:

1. Add normalized operation error structs.
2. Expand retry policy metadata and validation.
3. Normalize Google Sheets rate-limit, transient HTTP, network, credential, and validation
   errors.
4. Only after that, design durable retry persistence and runner resume.

Likely files:

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
