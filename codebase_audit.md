# Codebase Audit

Repository: `/Users/galdirie/code/fizz`.

This audit started as a read-only baseline for integration scalability. Since then, the
refactor has shipped metadata-first catalog foundations, resource locator/mapper support,
a credential ownership cleanup, and a shared typed field contract.

Current useful primitives include `Fizz.Integrations.StepDefinition`, `Fizz.Integrations.StepType`,
`Fizz.Workflows.StepExecutor`, `Fizz.Integrations.StepRegistry`,
`Fizz.Integrations.ProviderDefinition`, `Fizz.Integrations.DynamicResolver`,
`Fizz.Integrations.StaticIntegration`, `Fizz.Integrations.PlaceholderStep`,
`Fizz.Integrations.Fizz`, `Fizz.Fields`, `Fizz.Fields.Credential`, and schema-driven Vue field rendering.
The main remaining issue is turning the registered skeleton integration steps into real
Req-backed API clients with pinned step/workflow tests.

## 0. Refactor Updates

Resolved since the original audit:

- Generic `Fizz.Slots` modules and `Fizz.Workflows.SlotBinding` were deleted.
- Dedicated credential declaration/schema modules were deleted.
- Credential field declaration, option lookup, readiness, auto-binding, runtime binding
  resolution, and API-key secret extraction now live under `Fizz.Fields.Credential`.
- Credential fields use explicit `"$credential"` declarations plus `"ui"."component" ==
  "credential"` schema metadata.
- Provider credential creation inputs and step inputs now use the same
  `Fizz.Fields.Definition` contract, with JSON Schema plus `"ui"` generated as adapter
  output.
- The old step resolver behavior was deleted; edit-time dynamic values now route through
  `Fizz.Integrations.DynamicResolver`.
- `MapEditor.vue` was replaced by `ResourceMapperField.vue`.
- `RunLaunchModal.vue` and `SlotField.vue` were replaced by credential-named components.

Still open:

- provider modules still duplicate OAuth/API-key declaration boilerplate
- many non-Google integrations still need typed field cleanup
- execution context and Google Sheets step errors are now normalized; retryable step
  failures now persist through `workflow_runs.error` plus durable retry timers, but
  crash/passivation recovery coverage still needs hardening
- dynamic field state is reply-based, not durable server-side state
- Google Sheets append/read are normal step executors that own their fields, retry
  metadata, and step metadata directly
- Google Sheets now publishes retry metadata on step definitions and the client returns
  `Fizz.Workflows.StepError` instead of raw `{:backoff, ...}` or HTTP maps
- Remaining external skeleton products now have product integration modules, executable
  step modules colocated under integration namespaces, explicit step
  `provider`/`integration` metadata, and a shared `not_implemented` execution payload
  instead of ad hoc empty `%{}` returns.
- Product integration declaration files now live inside their product directories as
  `integration.ex`, keeping the integration root for shared catalog/framework modules.
- Providerless built-in/internal workflow nodes now belong to the `fizz` integration
  under `Fizz.Integrations.Fizz.Builtins`; step declaration/type metadata now lives in
  `Fizz.Integrations`, and the execution behavior lives in `Fizz.Workflows`.
- `Fizz.IntegrationStepCase` provides the first direct step harness for integration
  catalog tests.

## 1. Current Declarations and Boilerplate

Integration declarations are still manifest-driven, but executable ownership is now
attached to integration modules. Auth providers are listed in `Fizz.Integrations.ProviderCatalog` (`lib/fizz/integrations/provider_catalog.ex:9`). Product integrations are listed in the manifest and each integration exposes its own `step_modules/0`. `Fizz.Integrations.StepRegistry` loads step types by flattening those integration-owned module lists. Adding a real integration can still require a provider module, provider catalog edit, product integration module, step module, manifest edit, image assets, UI field support, and tests.

The product-level integration abstraction is now executable ownership plus product
metadata. Google Sheets advertises action step type IDs and owns append/read/trigger step
modules. Gmail, Slack, Notion, GitHub, Microsoft, Box, OpenAI, and Anthropic also have
product integration modules that group action IDs and step modules. Provider-owned
executable modules live under `Fizz.Integrations.<Product>.Actions`, `.Triggers`, or
`.Nodes`; providerless Fizz nodes live under `Fizz.Integrations.Fizz.Builtins`. Most
external product steps are still skeleton executors, but they now declare
provider/integration ownership explicitly and return a shared placeholder payload until
their API clients are implemented.

OAuth provider modules repeat the same shape. Slack, Google, Microsoft, Notion, and Box define `provider_id/0`, `display_name/0`, `definition/0`, `check_connection/2`, `fetch_token/2`, and `network_domains/0`, differing mainly by slug/logo/domains (`lib/fizz/integrations/providers/google_oauth.ex:14`, `lib/fizz/integrations/providers/slack_oauth.ex:14`, `lib/fizz/integrations/providers/box_oauth.ex:14`). `PipesOAuth` centralizes WorkOS token/status calls (`lib/fizz/integrations/providers/pipes_oauth.ex:6`), but not provider declaration boilerplate.

API-key providers have inconsistent implementation status. OpenAI implements `Fizz.Integrations.Provider` (`lib/fizz/integrations/providers/openai_api_key.ex:8`), while Anthropic, GitHub API key, and custom API key are catalog-only definitions with no provider behavior (`lib/fizz/integrations/providers/anthropic_api_key.ex:1`, `lib/fizz/integrations/providers/github_api_key.ex:1`). `ProviderDefinition.api_key/1` supports nil-module providers (`lib/fizz/integrations/provider_definition.ex:31`), and runtime auth falls back to generic vault resolution (`lib/fizz/integrations.ex:305`). This works, but it leaks "implemented vs definition-only" into execution branching.

Credential declarations are now explicit field definitions. Legacy executor modules
still repeat the same pattern: build a `Fizz.Fields.credential/2` and let
`Fizz.Integrations.StepDefinition` generate defaults and schema. That is much thinner than the old
credential module stack, but it is still boilerplate that should disappear as common
provider step helpers emerge.

## 2. Shared Abstractions vs. Copy-Paste

The code has several good abstractions that are not consistently used as the source of truth:

- `Fizz.Fields` now owns typed field definitions and adapts them to the JSON Schema plus
  `ui` extension model used by Vue, but most non-Google step fields are still
  generated from legacy executor modules.
- `Fizz.Fields.Credential` wraps credential declaration/schema generation, but each
  legacy executor still wires it manually.
- `Fizz.Integrations.resolve_auth_for_execution/4` validates credential refs and resolves API-key/OAuth credentials (`lib/fizz/integrations.ex:155`, `lib/fizz/integrations.ex:313`), while `OpenAIApiKey` repeats credential-ref normalization, owner checks, and vault resolution for organization-scoped helpers (`lib/fizz/integrations/providers/openai_api_key.ex:162`, `lib/fizz/integrations/providers/openai_api_key.ex:175`).

There are also context-level duplications. `GitHubOAuth` reimplements token-fetch flow directly through `Accounts.get_pipes_access_token/3` (`lib/fizz/integrations/providers/github_oauth.ex:29`, `lib/fizz/integrations/providers/github_oauth.ex:57`) rather than layering GitHub-specific metadata on top of the generic `PipesOAuth` path. Workspace console setup reaches directly into `Integrations` and provider registries (`lib/fizz_web/channels/workspace_console_channel.ex:4`, `lib/fizz_web/channels/workspace_console_channel.ex:149`), while similar provider setup exists in the workspace job worker (`lib/fizz/workspaces/workers/exec_job_worker.ex:252`).

The AI subnode path is a separate copy-paste hotspot. `OpenAIModel` and `AnthropicModel` duplicate credential schema, output shape, validation, and error mapping under their provider integration namespaces. `AIAgent` hardcodes accepted model subnodes and provider dispatch in `lib/fizz/integrations/fizz/builtins/ai_agent.ex`. Adding another LLM provider currently means adding a subnode and editing the agent.

## 3. UI to Backend Coupling

Workflow editor configuration is partially schema-driven. `WorkflowsLive.Editor` sends `stepTypes` and `nodeLibraryItems` into the LiveVue `WorkflowEditor` (`lib/fizz_web/live/workflows_live/editor.ex:63`). Step payloads include metadata plus config/input/output schema (`lib/fizz_web/live/workflows_live/payload.ex:50`). Vue interprets the backend `ui.component` values through a fixed TypeScript union (`assets/vue/types/configSchema.ts:12`), infers fields in `useStepConfig` (`assets/vue/components/flow/step_config/useStepConfig.ts:247`), and dispatches components in `FieldWrapper` (`assets/vue/components/flow/fields/FieldWrapper.vue:70`).

Dynamic options are still event-routed through the editor LiveView, but the resolver
lookup is now centralized in `Fizz.Integrations.DynamicResolver`. Credential fields are
handled as a field component type and dispatch to `Fizz.Fields.Credential`.
The remaining improvement is field-state ownership: loading and error state are still
transient Vue request state rather than durable LiveView/server state. Google Sheets
resolver failures now read normalized step errors, but no server process owns field state
across clients or reconnects.

The resource mapper is now generic enough for the next integration family:
`ResourceMapperField.vue` receives lookup fields, labels, and async error copy through
schema/resolver metadata. Continue keeping provider vocabulary out of Vue components.

The credentials settings UI now reads provider `credential_fields` through the same
field contract as step inputs. API-key providers get a generated password/secret
field by default, and providers can declare multiple secret or non-secret creation
fields without adding a credential-specific schema module. The next UI improvement is to
render those fields through the same component registry used by workflow step fields
instead of keeping credential-form-specific markup.

OAuth connection UI is delegated to WorkOS widget strings instead of internal provider definitions. Settings hardcode the `pipes` tab (`lib/fizz_web/live/user_management_live.ex:29`, `lib/fizz_web/live/user_management_live.html.heex:289`), and the JS hook maps widget names to React widgets (`assets/js/hooks/workos_react_widgets.js:30`). Workspace repository cloning is also GitHub-specific: the LiveView calls `Integrations.list_repos(..., "github_oauth", ...)` (`lib/fizz_web/live/workspaces_live/show.ex:432`) and renders GitHub-specific errors (`show.ex:461`, `show.html.heex:146`).

## 4. Naming, Modules, and Context Boundaries

The highest-risk boundary issue is a context cycle. `Fizz.Integrations` delegates persistence to `Fizz.Accounts.ExternalAuth` (`lib/fizz/integrations.ex:5`, `lib/fizz/integrations.ex:9`), while `Accounts.ExternalAuth` and `Accounts.ApiCredential` depend back on `Fizz.Integrations.ProviderCatalog` (`lib/fizz/accounts/external_auth.ex:12`, `lib/fizz/accounts/api_credential.ex:12`). Provider definition ownership should be one-way: either integration validation wraps credential persistence, or credential persistence owns provider-agnostic storage only.

Credential binding ownership is now explicit: `Fizz.Fields.Credential` owns field-facing
declaration and lookup behavior, and `Fizz.Workflows.CredentialBinding` owns the
workflow-specific schema. The generic slot context was removed instead of moved.

Project-scope resolution is repeated in LiveViews. Project routes are inside the authenticated LiveView session (`lib/fizz_web/router.ex:69`), while `UserAuth` mounts only the base current scope (`lib/fizz_web/user_auth.ex:329`). Several LiveViews rebuild project scope themselves (`lib/fizz_web/live/workflows_live/index.ex:48`, `workflows_live/editor.ex:340`, `workflows_live/revisions.ex:109`, `workspaces_live/index.ex:86`). `FizzWeb.Plugs.RequireProjectScope` exists (`lib/fizz_web/plugs/require_project_scope.ex:1`) but is not wired for LiveView. A shared authenticated project live_session/on_mount would reduce repeated scope code.

Runtime context naming is inconsistent. `ContextBuilder` stores both `:scope` and `:current_scope` (`lib/fizz/workflows/runtime/context_builder.ex:65`), and the assembler forwards both (`lib/fizz/workflows/compiler/assembler.ex:1625`). Google Sheets consumes `current_scope` (`lib/fizz/integrations/google/sheets/client.ex:223`), while AI Agent tries `scope`, `current_scope`, and metadata (`lib/fizz/integrations/fizz/builtins/ai_agent.ex`). A runtime struct such as `Fizz.Workflows.ExecutionContext` should use one canonical field.

Built-in executor file/module/id naming is now aligned for the previously inconsistent
aggregator and splitter steps. Keep that convention as new internal primitives are added.

## 5. Tests and Testability

Current coverage is strongest around auth, WorkOS, triggers, workflow execution, and editor server behavior. WorkOS HTTP/retry/vault behavior is covered (`test/fizz/accounts/workos_test.exs:56`), auth callback/session creation is covered (`test/fizz_web/controllers/workos_auth_controller_test.exs:130`), WorkOS webhooks are covered (`test/fizz_web/controllers/workos_webhook_controller_test.exs:23`), and credential/provider flows are covered in `test/fizz/integrations_test.exs:40`. Google Sheets has table discovery and resolver coverage (`test/fizz/integrations/google/sheets/client_test.exs:43`, `test/fizz/integrations/google/sheets/columns_resolver_test.exs:38`). Trigger and workflow runtime coverage is broad (`test/fizz/triggers/basic_triggers_integration_test.exs:18`, `test/fizz/workflows/runner/worker_test.exs:267`, `test/fizz/workflows/runner/worker_failure_test.exs:50`).

Coverage gaps line up with abstraction gaps. Phase 7 now has `Fizz.IntegrationStepCase`
for direct step definition lookup and execution, plus coverage that product integrations
point at concrete step type IDs. GitHub provider HTTP behavior is still hard to isolate
because `GitHubOAuth` calls `Req.get/2` and `Req.post/2` directly
(`lib/fizz/integrations/providers/github_oauth.ex:161`). Workspace provider HTTP has a
similar direct-Req gap (`lib/fizz/workspaces/providers/sprites/http.ex:80`). The next
testability gap is `Req.Test` transport seams plus pinned workflow fixtures for real
provider steps. LiveVue behavior is mostly tested through server hooks and props while
SSR is disabled in tests (`config/test.exs:3`), leaving client event payload construction
and field interactions thinly covered.

Some tests are brittle. Several mutate global application config, forcing `async: false` and increasing leakage risk (`test/fizz/accounts/workos_test.exs:22`, `test/fizz/integrations_test.exs:14`, `test/fizz_web/live/workflow_editor_live_test.exs:47`). Sleep/poll synchronization appears despite the project testing guidance (`test/fizz/workflows/runner/worker_failure_test.exs:467`, `test/fizz_web/live/workflow_editor_live_test.exs:1591`, `test/fizz/triggers/basic_triggers_integration_test.exs:276`). Some LiveView tests modify process internals with `:sys.replace_state/2` (`test/fizz_web/live/workflow_editor_live_test.exs:1577`), and raw SQL lease setup is duplicated in workflow tests (`test/fizz/workflows_test.exs:768`, `test/fizz/workflows/runner/worker_test.exs:605`).

The refactor should add test seams as first-class design goals: `Req.Test`-friendly transport modules, step-level fake contexts, catalog validation tests, workflow golden fixtures, and LiveVue component tests for schema rendering.
