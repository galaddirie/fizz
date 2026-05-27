# Adding an Integration Today

This document captures the current integration path before the metadata-first refactor. It is intentionally explicit about the friction so future catalog work can remove steps without losing behavior.

## Current Process

1. Add or update a provider module under `lib/fizz/integrations/providers/`.
   - OAuth providers usually implement `Fizz.Integrations.Provider` and return a `Fizz.Integrations.ProviderDefinition.oauth/2` definition.
   - API-key providers may either implement provider behavior, like OpenAI, or be definition-only through `ProviderDefinition.api_key/1`.
   - Provider IDs are auth-type specific, for example `google_oauth` or `openai_api_key`.

2. Register the provider in `Fizz.Integrations.ProviderCatalog`.
   - Add the module to the built-in provider list.
   - Keep the provider ID, label, logo path, auth type, and runtime module aligned.

3. Add or update the product integration module under `lib/fizz/integrations/`.
   - Implement `Fizz.Integrations.Integration`.
   - Expose `id/0`, `display_name/0`, `provider_id/0`, `actions/0`, `triggers/0`, and `required_scopes/1`.
   - Register the module in `Fizz.Integrations.Registry`.

4. Add step modules for provider API behavior.
   - Google Sheets keeps action and trigger modules under `lib/fizz/integrations/google/sheets/`.
   - Step modules own executable metadata and delegate provider-specific API calls to integration client/resolver helpers.

5. Declare every executable step with `Fizz.Steps.Definition`.
   - Use `Fizz.Steps.Definition` for the step metadata.
   - Add `@fields`, `@input_schema`, `@output_schema`, and optional `@retry`.
   - Declare credential fields with `Fizz.Fields.credential/3` when the step needs auth.
   - Let `Fizz.Fields.to_schema/1` generate the JSON Schema adapter output.

6. Register the executor module in `Fizz.Steps.Registry`.
   - Add the executor module to the built-in executor list.
   - The node library and runtime resolve step types from this registry today.

7. Add UI assets and schema support as needed.
   - Add logos or icons under the existing static asset paths.
   - Use existing `Fizz.Fields` components whenever possible.
   - New field components require coordinated backend schema, LiveVue type, and Vue renderer changes.

8. Add tests at the level touched by the integration.
   - Provider/catalog tests belong under `test/fizz/integrations`.
   - Executor tests belong under `test/fizz/steps/executors`.
   - Provider API behavior should use `Req.Test`-friendly seams where available.
   - Resolver tests should cover the backend options/resource data returned to the editor.

## Baseline Guardrails

`test/fizz/integrations/catalog_guardrails_test.exs` locks the current provider IDs, product integration IDs, step type IDs, credential field shapes, and notable UI component names. When a new integration is added through the current path, update those anchors intentionally.
