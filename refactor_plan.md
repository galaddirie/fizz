# Integration Refactor Plan

This plan is informed by n8n, but translated into idiomatic Elixir/Phoenix/OTP. The goal is not to port n8n's TypeScript architecture; the goal is to preserve its durable ideas: metadata-first integration definitions, generated catalogs, generic UI rendering, versioned operations, isolated credential/auth contracts, and test harnesses that make new integrations cheap.

## Current Checkpoints

- `8931099` completed Phases 0-4: catalog guardrails, unified definitions, operation-backed Google Sheets registry support, and schema-driven credential forms.
- `9ef8cfd` completed Phase 5: dynamic field resolver dispatch plus generic resource locator/mapper UI support.
- `d824f3d` deleted the generic slots system and replaced it with first-class credential declarations, credential bindings, and runtime credential resolution.
- Current uncommitted work moves Google Sheets operation metadata into the operation modules, deletes the old Google Sheets step wrappers, and dispatches operations with typed execution context.
- The next implementation slice should continue Phase 6 by normalizing operation errors and retry metadata before attempting durable retries.

## Diagnosis

1. **Declaration scatter is the main scalability blocker.** Providers, product integrations, and workflow steps are declared in separate lists: `ProviderCatalog` (`lib/fizz/integrations/provider_catalog.ex:9`), `Integrations.Registry` (`lib/fizz/integrations/registry.ex:55`), and `Steps.Registry` (`lib/fizz/steps/registry.ex:263`). Adding a real integration means keeping multiple registries and wrappers manually aligned.

2. **Operation metadata is not the source of truth.** `Fizz.Integrations.Operation` exists (`lib/fizz/integrations/operation.ex:1`), and Google Sheets uses operation modules, but the workflow editor still depends on hand-written executor modules and step registry entries. The target should be: operation definition produces the node library item, config schema, credential requirements, runtime dispatch, and tests.

3. **Credentials are generic in storage but not in declaration/UI.** WorkOS-backed OAuth and Vault-backed API keys are mostly generic, but provider modules and credential forms repeat boilerplate. API credential UI assumes one `secret` field (`lib/fizz_web/live/user_management_live.ex:481`, `user_management_live.html.heex:511`), so provider-specific credential schemas are missing.

4. **Context boundaries are still blurred, but credential ownership is cleaner.** `Accounts` and `Integrations` still depend on each other (`lib/fizz/integrations.ex:9`, `lib/fizz/accounts/external_auth.ex:12`). The generic slot API has been deleted and credential binding ownership now lives in `Fizz.Credentials` plus `Fizz.Workflows.CredentialBinding`. Runtime context still carries compatibility fields such as `scope` and `current_scope` (`lib/fizz/workflows/runtime/context_builder.ex:65`), which leaks Phoenix naming into execution code.

5. **The UI is schema-driven, but field-state ownership is still young.** Vue renders backend schema fields through `FieldWrapper` (`assets/vue/components/flow/fields/FieldWrapper.vue:70`), and `ResourceMapperField.vue` now uses schema/resolver metadata instead of Google Sheets-specific branches. `Fizz.Integrations.DynamicResolver` owns edit-time field dispatch, but there is not yet a durable server-side field-state model for cross-client async loading/error state.

6. **Tests cover workflows broadly but not integration operations as isolated units.** There is no ExUnit equivalent of n8n's workflow JSON plus pinned-output harness. Direct `Req` usage in provider/client modules makes some HTTP tests hard (`lib/fizz/integrations/providers/github_oauth.ex:161`).

## Target Architecture

### Core Modules

- `Fizz.Integrations.Catalog`: supervised GenServer/ETS registry for providers, credentials, integrations, operations, triggers, resolvers, and versions. It should load from a generated manifest and expose read-only lookup APIs.
- `Fizz.Integrations.Manifest`: generated module produced by a Mix task from declared integration modules. This replaces hand-maintained lists in `ProviderCatalog`, `Integrations.Registry`, and `Steps.Registry`.
- `Fizz.Integrations.Definition`: structs and validators for integration/provider/credential/operation definitions.
- `Fizz.Integrations.Provider`: provider metadata and auth-provider behavior. Keep WorkOS Pipes helpers behind `Fizz.Integrations.Auth.PipesOAuth`.
- `Fizz.Integrations.Credential`: credential declaration behavior/structs. Includes UI schema, auth type, storage adapter, and test operation.
- `Fizz.Integrations.Auth`: execution-time auth resolver returning typed auth material. It should support project-scoped and organization-scoped callers without duplicating `CredentialRef` logic.
- `Fizz.Integrations.Operation`: operation behavior. Operation modules own metadata, config schema, dynamic resolvers, and execution.
- `Fizz.Integrations.OperationExecutor`: one generic step executor that dispatches operation IDs to operation modules. This replaces per-operation wrapper executors over time.
- `Fizz.Integrations.DynamicResolver`: generic dispatcher for select/search/resource mapper fields. LiveView calls this instead of inspecting field internals directly.
- `Fizz.Credentials`: first-class context for credential declarations, field option lookup, per-user workflow bindings, readiness, auto-binding, and runtime credential refs.
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
%Fizz.Integrations.OperationDefinition{
  id: "google.sheets.append_row",
  step_type_id: "google_sheets_append_row",
  version: 1,
  provider: "google",
  auth: [
    %Fizz.Integrations.CredentialRequirement{
      key: "credential_ref",
      provider: "google_oauth",
      auth_type: :oauth,
      required: true,
      label: "Google Account"
    }
  ],
  display: %{
    name: "Google Sheets - Append Row",
    category: "Documents",
    icon: "/images/google_sheets.svg",
    description: "Append a new row of data to a Google Sheet"
  },
  config_schema: %{
    "type" => "object",
    "required" => ["credential_ref", "spreadsheet_id", "values"],
    "properties" => %{
      "credential_ref" => Fizz.Integrations.Schema.credential_field("credential_ref"),
      "spreadsheet_id" => Fizz.Integrations.Schema.resource_locator(
        title: "Spreadsheet",
        resolver: :spreadsheets
      ),
      "values" => Fizz.Integrations.Schema.resource_mapper(
        title: "Row Values",
        resolver: :columns,
        depends_on: ["credential_ref", "spreadsheet_id", "sheet_name", "table_id"]
      )
    }
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

Keep the existing JSON Schema plus `ui` extension, but make it a validated Fizz contract:

- Field types: `string`, `number`, `boolean`, `json`, `select`, `search`, `credential`, `resource_locator`, `resource_mapper`, `collection`.
- Visibility: `display` rules modeled after n8n's `displayOptions`, but simpler: `show_if`, `hide_if`, `feature`, and `version`.
- Dynamic data: `resolver: :spreadsheets`, `resolver: :columns`, `depends_on: [...]`, `params: %{...}`.
- Auth fields: declared through credential requirements, not hand-assembled per executor.

The Vue layer should continue to use a small component registry. `ResourceMapperField.vue`
is the generic mapper component; Google Sheets should supply resolver metadata and labels,
not custom component assumptions.

Current state: `ResourceMapperField.vue` and `DynamicResolver` now exist. Continue tightening this contract by keeping error copy, lookup labels, dependencies, and mapper defaults in schemas/resolver replies instead of Vue provider branches.

### OTP and Context Boundaries

- Supervise `Fizz.Integrations.Catalog`; store read-mostly data in ETS or `:persistent_term` plus an ETS index if reload is required in tests/dev.
- Use Oban for durable retries, scheduled sync, polling triggers, and backoff. Use ordinary supervised processes only for active in-memory subscriptions.
- Keep `Accounts` provider-agnostic. Provider validation and credential schema belongs to `Integrations`; credential persistence can either move to a new `Fizz.Credentials` context or remain in `Accounts.ExternalAuth` with no dependency back to `Integrations`.
- Route project LiveViews through the existing authenticated `live_session :require_authenticated_user` (`lib/fizz_web/router.ex:72`) because all workflow/project screens require login. Add a project-aware `on_mount` inside that session for project routes so LiveViews receive a resolved project scope once.

## Migration Path

### Phase 0 - Baseline and Guardrails

Create catalog validation tests around current providers, step IDs, credential fields, and schema field support. Add a short guide for adding an integration today so the baseline friction is explicit. No runtime behavior changes.

Status: shipped in `8931099`.

### Phase 1 - Append-Only Catalogs and Validation

Change provider/integration config extension from replacement semantics to append semantics. `:integration_providers` and `:integrations` should add to built-ins unless an explicit test-only replacement option is used. Add validation for duplicate IDs, invalid auth suffixes, missing icons, missing credential requirements, and unsupported UI components.

Status: shipped in `8931099`.

### Phase 2 - Introduce Unified Definitions

Add `OperationDefinition`, `CredentialRequirement`, `ProviderDefinition` improvements, and `Fizz.Integrations.Catalog`. Build adapters so current `Fizz.Steps.Type` entries can be produced from current executor modules and from operation definitions.

Status: shipped in `8931099`.

### Phase 3 - Operation-Driven Step Registry

Make `Fizz.Steps.Registry` consume operation definitions through `Fizz.Integrations.Catalog`. Add `Fizz.Integrations.OperationExecutor` as the generic executor for operation-backed step types. Migrate Google Sheets first because it already has product modules and operations. Keep old wrappers as compatibility adapters.

Status: shipped in `8931099`.

### Phase 4 - Credential Contract and Forms

Introduce credential definitions with provider-specific UI schema and credential-test metadata. Refactor API-key creation/rotation UI to render from credential schema instead of fixed `secret` params. Move or decouple `Accounts.ExternalAuth` so it no longer depends on `ProviderCatalog`. Add organization-scoped auth resolver so OpenAI helpers stop reimplementing credential ref logic.

Status: shipped in `8931099`, then tightened in `d824f3d`.

Follow-up result from `d824f3d`: generic slots were deleted. Credentials now have explicit declarations, option resolution, per-user bindings, and runtime credential refs. There are no backwards-compat shims.

### Phase 5 - Dynamic UI Resolver Layer

Replace editor-specific resolver inspection with `Fizz.Integrations.DynamicResolver.resolve/4`. Add schema-level `depends_on`, `display`, `resource_locator`, and `resource_mapper`. Keep `ResourceMapperField.vue` generic and move Google Sheets specifics into resolver outputs.

Status: shipped in `9ef8cfd`.

### Phase 6 - Execution Semantics

Introduce `Fizz.Workflows.ExecutionContext` and migrate executors/operations to it. Add normalized error structs, retry metadata, rate-limit/backoff handling, and per-operation network domain declarations. Use Oban for durable operation retries and polling/backoff, and supervised processes only for active subscriptions.

Current recommendation: split this phase. Typed operation context dispatch has started for Google Sheets operations. Continue with normalized operation errors and retry policy metadata. Add durable Oban retries only after the runner has a clear persistence and resume contract.

Shippable result: old executor `execute(config, input, context)` remains available while operation modules move to the typed context.

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
4. Should credential persistence move out of `Accounts` into a dedicated `Fizz.Credentials` context, or is removing the reverse dependency enough?
5. Which integration family should be the first migration after Google Sheets: Slack, GitHub, Gmail, or AI providers?
6. Do we need provider-specific rate limits and retry policies in v1 of the refactor, or only normalized error/backoff handling?
7. How much client-side Vue test coverage do we want for schema rendering versus LiveView integration tests and operation-level ExUnit tests?
