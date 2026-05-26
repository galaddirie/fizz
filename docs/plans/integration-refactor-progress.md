# Integration Refactor Handoff

Status date: 2026-05-26

This is the handoff point for the metadata-first integration refactor. It records what is
committed, what is implemented but still uncommitted, what has been validated, and the
recommended next steps for resuming Phase 6.

## Executive Summary

- Branch: `refactor/v0.2.0`
- Last committed checkpoint: `8931099b923bcbcbc32ca940c2140880bd8aa608`
- Last committed message: `feat(integrations): add metadata-first catalog foundation`
- Committed scope: Phases 0 through 4
- Current uncommitted scope: Phase 5 dynamic UI resolver layer
- Phase 5 status: implemented, reviewed, and validated
- Phase 6 status: architecture review completed, no Phase 6 code changes applied
- Immediate next decision: commit Phase 5 separately before starting Phase 6

## Important Handoff Notes

- Do not assume Phase 5 is committed. It is currently only in the working tree.
- Do not mix Phase 6 implementation into the Phase 5 diff unless intentionally choosing a
  larger combined commit.
- The `MapEditor.vue` to `ResourceMapperField.vue` rename is unstaged. When committing,
  stage both the deletion and new file so Git records the rename cleanly.
- Manual browser verification for Phase 5 did not complete because the local dev server
  and browser session had port/CORS setup friction. Automated validation passed.
- Phase 6 durable retries are not a small worker-only change. They need a persistence and
  workflow-runner resume contract.
- The user has explicitly accepted faster, more aggressive cleanup. Still keep phase
  checkpoints independently shippable when possible.

## Resume Checklist

Start a new session with these checks:

1. Inspect the working tree:

   ```sh
   git status --short
   git diff --stat
   ```

2. Review the Phase 5 diff before committing:

   ```sh
   git diff -- lib/fizz/integrations/dynamic_resolver.ex
   git diff -- lib/fizz_web/live/workflows_live/editor.ex
   git diff -- assets/vue/components/flow/fields/ResourceMapperField.vue
   ```

3. Re-run a quick whitespace check:

   ```sh
   git diff --check HEAD
   ```

4. If the diff still looks scoped to Phase 5, commit it separately. Suggested conventional
   commit message:

   ```text
   feat(integrations): add dynamic resolver layer
   ```

5. After the Phase 5 commit, start Phase 6 from a clean working tree.

## Validation Already Completed For Phase 5

The following commands passed after the Phase 5 review fixes:

```sh
mix test test/fizz/integrations/dynamic_resolver_test.exs test/fizz/integrations/catalog_validation_test.exs test/fizz_web/live/workflow_editor_live_test.exs
mix test
mix assets.build
mix precommit
```

`mix assets.build` emitted existing Vite warnings about third-party packages, but the build
completed successfully.

After this handoff document was added, only this doc was checked with:

```sh
git diff --check HEAD -- docs/plans/integration-refactor-progress.md
```

That check passed. `mix precommit` was not rerun for this doc-only handoff edit.

## Committed Work

Phases 0 through 4 are committed in:

```text
8931099b923bcbcbc32ca940c2140880bd8aa608
```

### Phase 0 - Baseline and Guardrails

- Added catalog regression tests for current providers, step types, and credential slot
  shapes.
- Added `ADDING_INTEGRATION.md` to document the previous multi-step integration flow.
- Established a baseline before runtime behavior changed.

### Phase 1 - Append-Only Catalogs and Validation

- Changed catalog configuration toward append-only behavior.
- Added startup validation for duplicate IDs, missing icons, credential requirements, and
  unsupported UI components.
- Added regression tests for validation failures.

### Phase 2 - Unified Definitions and Catalog GenServer

- Added the metadata definition layer.
- Added the generated manifest path.
- Added catalog APIs that run alongside the existing registries.
- Began decoupling provider ownership from credential lookup.

### Phase 3 - Operation-Driven Step Registry

- Added operation-driven step registry support.
- Added `Fizz.Integrations.OperationExecutor`.
- Migrated Google Sheets append-row and read-rows to the operation path.
- Preserved existing Google Sheets step executor wrappers as compatibility adapters.
- Added `Fizz.Workflows.ExecutionContext` with compatibility handling for legacy context
  fields.

### Phase 4 - Credential Contract and Forms

- Added credential definitions and schema-driven credential form support.
- Refactored API-key creation and rotation away from a fixed `secret`-only shape.
- Further decoupled external auth from provider catalog ownership.
- Added org-scoped auth resolution support for provider helpers.

## Uncommitted Phase 5 Work

Phase 5 implements the Dynamic UI Resolver Layer.

### Backend Changes

- Added `Fizz.Integrations.DynamicResolver`.
- Replaced editor-specific resolver inspection with `DynamicResolver.resolve/4`.
- Added schema metadata support for:
  - `depends_on`
  - `display`
  - `resource_locator`
  - `resource_mapper`
- Added validation for malformed resource metadata and mapper references.
- Made schema-owned resolver params authoritative over client payload params.
- Extended Google Sheets column resolver output with generic aliases:
  - `parent_id`
  - `parent_label`
  - `schema.columns`

### Frontend Changes

- Renamed:
  - from `assets/vue/components/flow/fields/MapEditor.vue`
  - to `assets/vue/components/flow/fields/ResourceMapperField.vue`
- Updated field component lookup to use:
  - `resource_locator`
  - `resource_mapper`
- Removed active Google Sheets-specific assumptions from the mapper component.
- Updated Vue schema types and step config field inference for the new resource field
  types.

### Phase 5 Review Result

An independent Phoenix/LiveView review found one material issue:

- Client-supplied resolver params could override schema-owned resolver constraints.

Fix applied:

- `DynamicResolver` now gives schema params precedence over payload params.

Re-review result:

- No blockers reported.

## Current Uncommitted File List

Expected Phase 5 implementation files:

- `lib/fizz/integrations/dynamic_resolver.ex`
- `lib/fizz_web/live/workflows_live/editor.ex`
- `lib/fizz/integrations/operation_definition.ex`
- `lib/fizz/integrations/definition.ex`
- `lib/fizz/integrations/manifest.ex`
- `lib/fizz/steps/registry.ex`
- `lib/fizz/steps/executors/google_sheets_append_row.ex`
- `lib/fizz/integrations/google/sheets/columns_resolver.ex`
- `assets/vue/components/flow/fields/ResourceMapperField.vue`
- `assets/vue/components/flow/fields/FieldWrapper.vue`
- `assets/vue/components/flow/step_config/useStepConfig.ts`
- `assets/vue/types/configSchema.ts`

Expected Phase 5 test/support files:

- `test/fizz/integrations/dynamic_resolver_test.exs`
- `test/fizz/integrations/catalog_validation_test.exs`
- `test/fizz/integrations/catalog_guardrails_test.exs`
- `test/fizz/integrations/catalog_test.exs`
- `test/fizz/integrations/google/sheets/columns_resolver_test.exs`
- `test/fizz/steps/executors/google_sheets_append_row_test.exs`
- `test/fizz_web/live/workflow_editor_live_test.exs`
- `test/support/catalog_validation/invalid_resource_metadata_step.ex`
- `test/support/catalog_validation/invalid_resource_mapper_reference_step.ex`

Expected deletion/rename source:

- `assets/vue/components/flow/fields/MapEditor.vue`

This handoff file is also uncommitted:

- `docs/plans/integration-refactor-progress.md`

## Current `git status --short`

At the time of this handoff, the working tree showed:

```text
 M assets/vue/components/flow/fields/FieldWrapper.vue
 D assets/vue/components/flow/fields/MapEditor.vue
 M assets/vue/components/flow/step_config/useStepConfig.ts
 M assets/vue/types/configSchema.ts
 M lib/fizz/integrations/definition.ex
 M lib/fizz/integrations/google/sheets/columns_resolver.ex
 M lib/fizz/integrations/manifest.ex
 M lib/fizz/integrations/operation_definition.ex
 M lib/fizz/steps/executors/google_sheets_append_row.ex
 M lib/fizz/steps/registry.ex
 M lib/fizz_web/live/workflows_live/editor.ex
 M test/fizz/integrations/catalog_guardrails_test.exs
 M test/fizz/integrations/catalog_test.exs
 M test/fizz/integrations/catalog_validation_test.exs
 M test/fizz/integrations/google/sheets/columns_resolver_test.exs
 M test/fizz/steps/executors/google_sheets_append_row_test.exs
 M test/fizz_web/live/workflow_editor_live_test.exs
?? assets/vue/components/flow/fields/ResourceMapperField.vue
?? docs/plans/integration-refactor-progress.md
?? lib/fizz/integrations/dynamic_resolver.ex
?? test/fizz/integrations/dynamic_resolver_test.exs
?? test/support/catalog_validation/invalid_resource_mapper_reference_step.ex
?? test/support/catalog_validation/invalid_resource_metadata_step.ex
```

## Phase 6 Architecture Findings

Phase 6 was explored with a read-only architecture sub-agent. No Phase 6 implementation
changes have been applied.

### Existing Foundation

- `Fizz.Workflows.ExecutionContext` already exists, but still acts partly as a legacy
  context compatibility wrapper.
- `Fizz.Integrations.OperationExecutor` is the cleanest boundary for operation-backed
  steps.
- `Fizz.Integrations.Operation` callbacks still use the old
  `execute(config, input, context)` shape.
- `Fizz.Integrations.RetryPolicy` exists, but only supports minimal retry metadata.
- Google Sheets client code already detects HTTP 429 and returns backoff information, but
  the result is not normalized into a first-class operation error.
- Oban is already installed and supervised, but there is no dedicated `:operations`
  queue.

### Phase 6 Constraint

Durable operation retries require more than an Oban worker.

The workflow runner currently executes a runnable synchronously and treats runnable
failure as run failure. A real durable retry path needs to:

1. persist retry intent and operation inputs
2. schedule retry through Oban
3. run the operation in an Oban worker
4. feed the retry result back into the workflow runner as the original runnable completion
5. fail the runnable only after retry exhaustion

Existing `step_executions` records include attempt-related fields, but they are not enough
for an Oban handoff because the retry worker needs durable operation-specific state and a
runner resume path.

## Recommended Phase 6 Slice

Keep Phase 6 scoped to operation-backed Google Sheets actions first. Do not migrate every
legacy executor in one pass.

Recommended implementation order:

1. Add normalized operation error structs.
2. Expand retry policy metadata and validation.
3. Change operation modules to receive `%Fizz.Workflows.ExecutionContext{}`.
4. Keep legacy step executors on their existing `execute(config, input, context)` API.
5. Update `OperationExecutor` to adapt legacy runtime context into typed operation
   context.
6. Migrate Google Sheets append-row and read-rows operation modules to the typed context
   callback.
7. Normalize Google Sheets rate-limit, transient HTTP, network, credential, and validation
   errors.
8. Add an `:operations` Oban queue.
9. Add a dedicated operation retry persistence model and Oban worker.
10. Add the narrow workflow-runner hook required to resume the original runnable from a
    completed retry.

## Phase 6 Files Likely To Change

- `lib/fizz/workflows/execution_context.ex`
- `lib/fizz/workflows/compiler/assembler.ex`
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
- `lib/fizz/integrations/google/sheets/columns_resolver.ex`
- `config/config.exs`
- `lib/fizz/workflows/operation_retry.ex`
- `lib/fizz/workflows/workers/operation_retry_worker.ex`
- `lib/fizz/workflows.ex`
- `lib/fizz/workflows/runner/worker.ex`

## Phase 6 Tests To Add Or Extend

- `test/fizz/workflows/execution_context_test.exs`
- `test/fizz/workflows/runtime/context_builder_test.exs`
- `test/fizz/integrations/operation_executor_test.exs`
- `test/fizz/integrations/operation_error_test.exs`
- `test/fizz/integrations/retry_policy_test.exs`
- `test/fizz/integrations/catalog_validation_test.exs`
- `test/fizz/integrations/google/sheets/client_test.exs`
- `test/fizz/integrations/google/sheets/columns_resolver_test.exs`
- `test/fizz/workflows/operation_retry_test.exs`
- `test/fizz/workflows/workers/operation_retry_worker_test.exs`

## Phase 6 Skills And Constraints To Remember

- Elixir changes require the Elixir guidance.
- Test changes require the ExUnit/testing guidance.
- Oban changes require the Oban guidance.
- OTP/supervision changes require the OTP guidance.
- Any schema, query, or migration work requires the Ecto guidance.
- HTTP must use `Req` only.
- Run `mix precommit` after Phase 6 changes are complete.

## Remaining Work From Original Plan

### Phase 6 - Execution Semantics

- Migrate operation execution to typed execution context.
- Keep adapters for legacy executor signatures during migration.
- Add normalized operation errors.
- Add retry metadata and rate-limit/backoff handling.
- Add Oban-backed durable operation retries.
- Validate with targeted tests, `mix test`, and `mix precommit`.

### Phase 7 - Testing Harness and Scaffolding

- Add an integration test harness with workflow fixtures, pinned outputs, credential
  fixtures, `Req.Test` expectations, and direct operation execution.
- Colocate integration fixtures beside integration modules.
- Add `mix fizz.gen.integration <provider>.<resource>`.
- Replace brittle tests that rely on `Process.sleep`.
- Remove `:sys.replace_state/2` test hacks where possible.
- Deduplicate raw SQL lease setup.
- Run full `mix test` and `mix precommit`.
