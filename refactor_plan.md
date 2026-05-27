# Integration Refactor Plan

This plan is informed by n8n, but translated into idiomatic Elixir/Phoenix/OTP. The goal is not to port n8n's TypeScript architecture; the goal is to preserve its durable ideas: metadata-first integration definitions, generated catalogs, generic UI rendering, versioned operations, isolated credential/auth contracts, and test harnesses that make new integrations cheap.

## Current Checkpoints

- `8931099` completed Phases 0-4: catalog guardrails, unified definitions, operation-backed Google Sheets registry support, and schema-driven credential forms.
- `9ef8cfd` completed Phase 5: dynamic field resolver dispatch plus generic resource locator/mapper UI support.
- `d824f3d` deleted the generic slots system and replaced it with first-class credential declarations, credential bindings, and runtime credential resolution.
- `4944cce` moved Google Sheets operation metadata into operation modules, deleted the old Google Sheets step wrappers, and dispatches operations with typed execution context.
- Current uncommitted work consolidates credential declarations/schema/defaults into the shared `Fizz.Fields` contract, adds normalized operation errors, normalizes Google Sheets client failures, publishes declarative retry metadata for Google Sheets operations, and gives the runner a durable retry timer path for retryable operation failures.
- The next implementation slice should continue Phase 6 by hardening retry resume around worker crashes/passivation and then deciding whether operation retries should stay on the existing durable timer/worker model or move into Oban.

## Diagnosis

1. **Declaration scatter is the main scalability blocker.** Providers, product integrations, and workflow steps are declared in separate lists: `ProviderCatalog` (`lib/fizz/integrations/provider_catalog.ex:9`), `Integrations.Registry` (`lib/fizz/integrations/registry.ex:55`), and `Steps.Registry` (`lib/fizz/steps/registry.ex:263`). Adding a real integration means keeping multiple registries and wrappers manually aligned.

2. **Operation metadata is not the source of truth.** `Fizz.Integrations.Operation` exists (`lib/fizz/integrations/operation.ex:1`), and Google Sheets uses operation modules, but the workflow editor still depends on hand-written executor modules and step registry entries. The target should be: operation definition produces the node library item, config schema, credential requirements, runtime dispatch, and tests.

3. **Credentials are runtime auth primitives, not a parallel field system.** WorkOS-backed OAuth and Vault-backed API keys are mostly generic, and provider definitions now expose credential creation fields through `Fizz.Fields`. Workflow credential binding storage remains, but declaration maps, schema generation, defaults, option lookup, readiness, auto-binding, runtime binding lookup, and secret extraction now live under the credential field handler instead of dedicated credential schema/catalog modules.

4. **Context boundaries are still blurred, but field ownership is cleaner.** `Accounts` and `Integrations` still depend on each other (`lib/fizz/integrations.ex:9`, `lib/fizz/accounts/external_auth.ex:12`). The generic slot API has been deleted, credential declaration behavior now lives in `Fizz.Fields.Credential`, and workflow-specific persisted choices still live in `Fizz.Workflows.CredentialBinding`. Runtime context still carries compatibility fields such as `scope` and `current_scope` (`lib/fizz/workflows/runtime/context_builder.ex:65`), which leaks Phoenix naming into execution code.

5. **The UI is schema-driven, but field-state ownership is still young.** Vue renders backend schema fields through `FieldWrapper` (`assets/vue/components/flow/fields/FieldWrapper.vue:70`), and `ResourceMapperField.vue` now uses schema/resolver metadata instead of Google Sheets-specific branches. `Fizz.Integrations.DynamicResolver` owns edit-time field dispatch, and Google Sheets async failures now normalize through `Fizz.Integrations.OperationError`, but there is not yet a durable server-side field-state model for cross-client async loading/error state.

6. **Tests cover workflows broadly but not integration operations as isolated units.** There is no ExUnit equivalent of n8n's workflow JSON plus pinned-output harness. Direct `Req` usage in provider/client modules makes some HTTP tests hard (`lib/fizz/integrations/providers/github_oauth.ex:161`).

## Target Architecture

### Core Modules

- `Fizz.Integrations.Catalog`: supervised GenServer/ETS registry for providers, integrations, operations, triggers, resolvers, and versions. It should load from a generated manifest and expose read-only lookup APIs.
- `Fizz.Integrations.Manifest`: generated module produced by a Mix task from declared integration modules. This replaces hand-maintained lists in `ProviderCatalog`, `Integrations.Registry`, and `Steps.Registry`.
- `Fizz.Integrations.Definition`: structs and validators for integration/provider/operation definitions, delegating field validation to `Fizz.Fields`.
- `Fizz.Fields`: canonical typed field contract plus JSON Schema adapter output. It owns field definitions, validation, defaults, and schema generation for operation fields and provider credential-creation fields.
- `Fizz.Fields.Credential`: credential field handler. It owns credential declaration maps, option lookup, readiness descriptors, auto-binding, runtime binding lookup, and secret extraction for API-key credential creation.
- `Fizz.Integrations.Provider`: provider metadata and auth-provider behavior. Keep WorkOS Pipes helpers behind `Fizz.Integrations.Auth.PipesOAuth`.
- `Fizz.Integrations.Auth`: execution-time auth resolver returning typed auth material. It should support project-scoped and organization-scoped callers without duplicating `CredentialRef` logic.
- `Fizz.Integrations.Operation`: operation behavior. Operation modules own metadata, config schema, dynamic resolvers, and execution.
- `Fizz.Integrations.OperationExecutor`: one generic step executor that dispatches operation IDs to operation modules. This replaces per-operation wrapper executors over time.
- `Fizz.Integrations.DynamicResolver`: generic edit-time dispatcher for select/search/resource mapper fields. Credential options dispatch through `Fizz.Fields.Credential` as a field handler, not as a separate resolver subsystem.
- `Fizz.Workflows.ExecutionContext`: typed runtime context struct with one canonical scope field, project ID, user ID, organization ID, run ID, trace context, and execution options.

### Integration Contract

The contract should be data-first, with behaviours for runtime hooks. Example target shape:

```elixir
defmodule Fizz.Integrations.Integration do
  @callback definition() :: Fizz.Integrations.Definition.t()
end

defmodule Fizz.Integrations.Operation do
  @callback definition() :: Fizz.Integrations.OperationDefinition.t()

  @callback execute(
              Fizz.Workflows.ExecutionContext.t(),
              config :: map(),
              input :: term()
            ) :: {:ok, term()} | {:error, Fizz.Integrations.Error.t() | term()}

  @callback resolve(
              Fizz.Workflows.ExecutionContext.t(),
              resolver :: atom(),
              params :: map()
            ) :: {:ok, [map()]} | {:error, term()}

  @optional_callbacks resolve: 3
end
```

Example operation definition:

```elixir
fields = [
  Fizz.Fields.credential("credential_ref",
    label: "Google Account",
    provider: "google_oauth",
    auth_type: :oauth,
    requirement_key: "auth",
    required?: true
  ),
  Fizz.Fields.resource_locator("spreadsheet_id", %{
    "kind" => "google_sheets.spreadsheet",
    "value_key" => "spreadsheet_id"
  },
    label: "Spreadsheet",
    depends_on: ["credential_ref"]
  ),
  Fizz.Fields.resource_mapper("values", %{
    "kind" => "google_sheets.row_values",
    "fields" => %{
      "primary_resource" => "sheet_name",
      "schema_resource" => "table_id"
    }
  },
    label: "Row Values",
    resolver: Fizz.Integrations.Google.Sheets.ColumnsResolver,
    depends_on: ["credential_ref", "spreadsheet_id", "sheet_name", "table_id"]
  )
]

%Fizz.Integrations.OperationDefinition{
  id: "google.sheets.append_row",
  step_type_id: "google_sheets_append_row",
  version: 1,
  provider: "google",
  fields: fields,
  config_schema: Fizz.Fields.to_schema(fields),
  display: %{
    name: "Google Sheets - Append Row",
    category: "Documents",
    icon: "/images/google_sheets.svg",
    description: "Append a new row of data to a Google Sheet"
  },
  output_schema: %{
    "type" => "object",
    "properties" => %{
      "updated_range" => %{"type" => "string"},
      "updated_rows" => %{"type" => "integer"}
    }
  },
  retry: %Fizz.Integrations.RetryPolicy{max_attempts: 3, backoff: :exponential}
}
```

### Schema That Drives UI

Keep the existing JSON Schema plus `ui` extension, but make it adapter output from a validated Fizz field contract:

- Field types: `string`, `number`, `boolean`, `json`, `select`, `search`, `credential`, `resource_locator`, `resource_mapper`, `hidden`, and `password`.
- Visibility: `display` rules modeled after n8n's `displayOptions`, but simpler: `show_if`, `hide_if`, `feature`, and `version`.
- Dynamic data: `resolver: :spreadsheets`, `resolver: :columns`, `depends_on: [...]`, `params: %{...}`.
- Auth fields: declared as `Fizz.Fields.credential/2` fields. The persisted config value remains the `"$credential"` declaration map used by workflow binding and runtime auth resolution.

The Vue layer should continue to use a small component registry. `ResourceMapperField.vue`
is the generic mapper component; Google Sheets should supply resolver metadata and labels,
not custom component assumptions.

Current state: `ResourceMapperField.vue`, `DynamicResolver`, and `Fizz.Fields` now exist. Continue tightening this contract by keeping error copy, lookup labels, dependencies, and mapper defaults in field definitions/resolver replies instead of Vue provider branches.

### OTP and Context Boundaries

- Supervise `Fizz.Integrations.Catalog`; store read-mostly data in ETS or `:persistent_term` plus an ETS index if reload is required in tests/dev.
- Use Oban for durable retries, scheduled sync, polling triggers, and backoff. Use ordinary supervised processes only for active in-memory subscriptions.
- Keep `Accounts` provider-agnostic. Provider validation and credential creation fields belong to `Integrations`/`Fizz.Fields`; token and secret persistence can remain in `Accounts.ExternalAuth` and Vault as long as those layers do not need to know about field rendering.
- Route project LiveViews through the existing authenticated `live_session :require_authenticated_user` (`lib/fizz_web/router.ex:72`) because all workflow/project screens require login. Add a project-aware `on_mount` inside that session for project routes so LiveViews receive a resolved project scope once.

## Migration Path

### Phase 0 - Baseline and Guardrails

Create catalog validation tests around current providers, step IDs, credential fields, and schema field support. Add a short guide for adding an integration today so the baseline friction is explicit. No runtime behavior changes.

Status: shipped in `8931099`.

### Phase 1 - Append-Only Catalogs and Validation

Change provider/integration config extension from replacement semantics to append semantics. `:integration_providers` and `:integrations` should add to built-ins unless an explicit test-only replacement option is used. Add validation for duplicate IDs, invalid auth suffixes, missing icons, missing credential requirements, and unsupported UI components.

Status: shipped in `8931099`.

### Phase 2 - Introduce Unified Definitions

Add `OperationDefinition`, provider definition improvements, field validation foundations, and `Fizz.Integrations.Catalog`. Build adapters so current `Fizz.Steps.Type` entries can be produced from current executor modules and from operation definitions.

Status: shipped in `8931099`.

### Phase 3 - Operation-Driven Step Registry

Make `Fizz.Steps.Registry` consume operation definitions through `Fizz.Integrations.Catalog`. Add `Fizz.Integrations.OperationExecutor` as the generic executor for operation-backed step types. Migrate Google Sheets first because it already has product modules and operations. Keep old wrappers as compatibility adapters.

Status: shipped in `8931099`.

### Phase 4 - Credential Contract and Forms

Introduce provider-owned credential creation fields and credential-test metadata. Refactor API-key creation/rotation UI to render from field definitions instead of fixed `secret` params. Move or decouple `Accounts.ExternalAuth` so it no longer depends on `ProviderCatalog`. Add organization-scoped auth resolver so OpenAI helpers stop reimplementing credential ref logic.

Status: shipped in `8931099`, then tightened in `d824f3d`.

Follow-up result from `d824f3d`: generic slots were deleted. Credentials gained explicit declarations, option resolution, per-user bindings, and runtime credential refs. The current uncommitted field-consolidation slice deletes the dedicated credential declaration/schema modules and moves field-facing credential behavior into `Fizz.Fields.Credential`; provider/auth runtime logic stays in provider/auth modules. There are no backwards-compat shims.

### Phase 5 - Dynamic UI Resolver Layer

Replace editor-specific resolver inspection with `Fizz.Integrations.DynamicResolver.resolve/4`. Add schema-level `depends_on`, `display`, `resource_locator`, and `resource_mapper`. Keep `ResourceMapperField.vue` generic and move Google Sheets specifics into resolver outputs.

Status: shipped in `9ef8cfd`.

### Phase 6 - Execution Semantics

Introduce `Fizz.Workflows.ExecutionContext` and migrate executors/operations to it. Add normalized error structs, retry metadata, rate-limit/backoff handling, and per-operation network domain declarations. Use Oban for durable operation retries and polling/backoff, and supervised processes only for active subscriptions.

Current recommendation: keep this phase split. Typed operation context dispatch has shipped for Google Sheets operations. Normalized operation errors, retry policy metadata, and the first runner persistence/resume contract now exist: executor failures are wrapped in `Fizz.Workflows.StepExecutionError`, retryable `OperationError` values are persisted on `workflow_runs.error`, and the worker schedules durable `operation_retry_v1` timers that resume the same runnable with incremented attempt metadata.

Shippable result: old executor `execute(config, input, context)` remains available while operation modules move to the typed context and return normalized errors.

### Phase 7 - Testing Harness and Scaffolding

Add an ExUnit integration harness inspired by n8n's `NodeTestHarness`: workflow fixture input, pinned outputs, credential fixtures, `Req.Test` HTTP expectations, and operation-level direct execution. Add a Mix task such as `mix fizz.gen.integration google.sheets` to scaffold provider, credential, operation, resolver, tests, docs, and assets.

Shippable result: new integrations have a paved path; old tests remain valid while new operation tests grow.

## What We Are Not Borrowing From n8n

- TypeScript class inheritance and `VersionedNodeType` as-is. In Elixir, use behaviours, structs, and explicit version fields.
- Runtime package scanning from `node_modules`. Use generated manifests and supervised registries.
- Large frontend-specific state/store architecture. Keep LiveView as the source of truth and Vue as schema-driven UI.
- Arbitrary dynamic code loading for community integrations until product/security requirements justify it. Start with compile-time modules and generated manifests.
- Per-node request helper objects that hide too much mutable execution state. Use explicit operation context structs and Req-backed transport modules.
- Massive all-purpose schemas with every n8n field type. Start with the field types Fizz needs and validate them strictly.

## Open Questions

1. Should integrations eventually be installable outside the repo, or is "thousands of integrations" still a monorepo/catalog problem for now?
2. Should WorkOS Pipes remain the only OAuth implementation, or do we need first-party OAuth flows for providers not supported by WorkOS?
3. Do workflow definitions need long-term per-operation version pinning before public launch, or can we migrate existing drafts/runs in place for now?
4. Should `credential_bindings` eventually be renamed or moved after launch, or is the current workflow-specific persistence name acceptable once field declaration ownership is fully under `Fizz.Fields.Credential`?
5. Which integration family should be the first migration after Google Sheets: Slack, GitHub, Gmail, or AI providers?
6. Do we need provider-specific rate limits and retry policies in v1 of the refactor, or only normalized error/backoff handling?
7. How much client-side Vue test coverage do we want for schema rendering versus LiveView integration tests and operation-level ExUnit tests?
