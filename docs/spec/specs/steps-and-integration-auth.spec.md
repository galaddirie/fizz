# Step Types And Integration Auth

This spec covers the implemented contracts for step type registration, executor
dispatch, integration provider identity, and credential resolution.

```spec-meta
id: steps.integration_auth
kind: service
status: active
summary: Step types are compile-time code artifacts registered in ETS, while integration auth flows through typed provider ids and metadata-only credential references.
surface:
  - lib/fizz/steps/definition.ex
  - lib/fizz/steps/type.ex
  - lib/fizz/steps/registry.ex
  - lib/fizz/steps/resolver.ex
  - lib/fizz/steps/executors/behaviour.ex
  - lib/fizz/integrations/provider.ex
  - lib/fizz/integrations/provider_catalog.ex
  - lib/fizz/integrations/credential_ref.ex
  - lib/fizz/integrations/credentials_resolver.ex
  - test/fizz/steps/resolver_test.exs
  - test/fizz/steps/type_subnodes_test.exs
  - test/fizz/integrations/credentials_resolver_test.exs
  - test/fizz/integrations_test.exs
```

## Requirements

```spec-requirements
- id: steps.integration_auth.definition_macro
  statement: Step types are declared in executor modules with compile-time validation of required metadata and produce a read-only step definition struct plus default config helpers.
  priority: must
  stability: stable

- id: steps.integration_auth.registry
  statement: The step registry loads a fixed built-in executor list into an ETS table at startup, rejects duplicate step ids, and serves lookup, grouping, category, kind, and library-item queries from that in-memory catalog.
  priority: must
  stability: stable

- id: steps.integration_auth.executor_contract
  statement: Executors resolve by step type id and must return `{:ok, output}`, `{:error, reason}`, or `{:skip, reason}`, with optional config validation and default-config callbacks.
  priority: must
  stability: stable

- id: steps.integration_auth.subnode_metadata
  statement: Step metadata supports root and subnode roles, and root types may publish subnode input declarations through registry metadata.
  priority: must
  stability: stable

- id: steps.integration_auth.provider_ids
  statement: Integration provider ids are auth-type specific and callers must use typed ids such as `<base>_oauth` and `<base>_api_key`.
  priority: must
  stability: stable

- id: steps.integration_auth.provider_resolution
  statement: A provider may be cataloged without an implementation module, in which case module lookup returns `:provider_not_implemented` rather than pretending the provider is unknown.
  priority: must
  stability: stable

- id: steps.integration_auth.credential_refs
  statement: Credential references are metadata-only values normalized to `id`, `provider`, `auth_type`, and `owner_user_id`, and they must reject provider, auth-type, or ownership mismatches.
  priority: must
  stability: stable

- id: steps.integration_auth.credentials_resolver
  statement: The credentials resolver requires `current_scope` with an organization id, filters by provider and auth type, supports search across option metadata, and caps returned options at 50.
  priority: must
  stability: stable
```

## Scenarios

```spec-scenarios
- id: steps.integration_auth.ai_subnodes
  given:
    - the step registry is initialized
  when:
    - the AI agent root type and model types are queried
  then:
    - `ai_agent` exposes declared subnode inputs
    - provider model nodes register with `node_role: :subnode`
  covers:
    - steps.integration_auth.registry
    - steps.integration_auth.subnode_metadata

- id: steps.integration_auth.resolve_credential_options
  given:
    - credential options exist for a scoped organization
  when:
    - the credentials resolver receives provider, auth-type, and search filters
  then:
    - only matching options are returned
    - the result set is limited to 50 entries
  covers:
    - steps.integration_auth.credentials_resolver

- id: steps.integration_auth.resolve_openai_provider
  given:
    - the provider catalog contains `openai_api_key`
  when:
    - the catalog resolves its API-key module and network domains
  then:
    - the implemented provider module is returned
    - provider network domains are exposed through the integration layer
  covers:
    - steps.integration_auth.provider_ids
    - steps.integration_auth.provider_resolution
```

## Verification

```spec-verification
- kind: source_file
  target: lib/fizz/steps/definition.ex
  covers:
    - steps.integration_auth.definition_macro

- kind: source_file
  target: lib/fizz/steps/type.ex
  covers:
    - steps.integration_auth.subnode_metadata

- kind: source_file
  target: lib/fizz/steps/registry.ex
  covers:
    - steps.integration_auth.registry

- kind: source_file
  target: lib/fizz/steps/executors/behaviour.ex
  covers:
    - steps.integration_auth.executor_contract

- kind: source_file
  target: lib/fizz/integrations/provider_catalog.ex
  covers:
    - steps.integration_auth.provider_ids
    - steps.integration_auth.provider_resolution

- kind: source_file
  target: lib/fizz/integrations/credential_ref.ex
  covers:
    - steps.integration_auth.credential_refs

- kind: source_file
  target: lib/fizz/integrations/credentials_resolver.ex
  covers:
    - steps.integration_auth.credentials_resolver

- kind: test_file
  target: test/fizz/steps/type_subnodes_test.exs
  covers:
    - steps.integration_auth.subnode_metadata
    - steps.integration_auth.ai_subnodes

- kind: test_file
  target: test/fizz/steps/resolver_test.exs
  covers:
    - steps.integration_auth.executor_contract
    - steps.integration_auth.credentials_resolver

- kind: test_file
  target: test/fizz/integrations/credentials_resolver_test.exs
  covers:
    - steps.integration_auth.credentials_resolver
    - steps.integration_auth.resolve_credential_options

- kind: test_file
  target: test/fizz/integrations_test.exs
  covers:
    - steps.integration_auth.provider_ids
    - steps.integration_auth.provider_resolution
    - steps.integration_auth.resolve_openai_provider
```

## Exceptions

```spec-exceptions
- id: steps.integration_auth.definition_only_providers
  note: Some registered step types and cataloged providers are intentionally metadata-only entries, so registration or catalog presence does not imply the external side effect is already implemented.
  relates_to:
    - steps.integration_auth.registry
    - steps.integration_auth.provider_resolution
```
