# Editor Step Configuration

Step configuration is the core authoring experience. Each step type declares a `config_schema` (JSON Schema with `ui` extensions) that drives a schema-driven config modal. This spec covers the schema-to-UI mapping, expression editing contracts, credential resolution, and subnode input management.

~~~spec-meta
id: editor.step_config
kind: component
status: active
summary: Config schema to UI field mapping, expression editing, credential resolution, and subnode inputs.
surface:
  - assets/vue/composables/workflow/useStepConfig.ts
  - assets/vue/components/workflow/step-config/StepConfigModal.vue
  - assets/vue/components/workflow/step-config/StepConfigConfigPane.vue
  - lib/fizz/workflows/expressions.ex
~~~

## Requirements

~~~spec-requirements
- id: editor.step_config.req_schema_driven_fields
  statement: The config modal renders fields dynamically from the step type's `config_schema`. The mapping from JSON Schema patterns to UI field types is deterministic and follows a fixed precedence order.
  priority: must
  stability: stable

- id: editor.step_config.req_field_type_precedence
  statement: "Field type inference follows this precedence: (1) `ui.component === \"search\"` maps to search/autocomplete, (2) `ui.component === \"select\"` maps to select dropdown, (3) `enum` present maps to select dropdown, (4) `format === \"json\"` maps to JSON editor, (5) `format === \"textarea\"` maps to multi-line textarea, (6) `type === \"number\"` or `\"integer\"` maps to number input, (7) `type === \"boolean\"` maps to toggle, (8) `type === \"object\"` without ui maps to nested JSON, (9) default maps to text input."
  priority: must
  stability: stable

- id: editor.step_config.req_expression_mode_toggle
  statement: Each config field has a Fixed/Expression mode toggle. In expression mode, the field input accepts `{{ }}` and `{% %}` template syntax.
  priority: must
  stability: stable

- id: editor.step_config.req_expression_auto_detect
  statement: If a field value contains `{{` or `{%`, the field automatically switches to expression mode.
  priority: should
  stability: stable

- id: editor.step_config.req_expression_preview_debounced
  statement: Expression preview requests are debounced (300ms) and sent to the server via `preview_expression`. The server evaluates the expression against assembled context and returns `{:ok, result}` or `{:error, message}`.
  priority: must
  stability: stable

- id: editor.step_config.req_preview_context_assembly
  statement: "Expression preview context includes four namespaces: `steps` (upstream step outputs from pinned outputs, then execution outputs, then schema placeholders), `input` (current step input schema fields), `workflow` (definition id and name), and `env` (platform values)."
  priority: must
  stability: stable

- id: editor.step_config.req_credential_resolver
  statement: Fields with `ui.component === "search"` and a `ui.resolver` pointing to `CredentialsResolver` trigger server-side credential search. The LiveView calls the resolver with scope and provider filter, returning `[{id, provider, display_name, auth_type, owner_display_name}]`.
  priority: must
  stability: stable

- id: editor.step_config.req_subnode_cardinality
  statement: Subnode inputs with `cardinality: :one` accept at most one connected subnode; inputs with `cardinality: :many` accept multiple.
  priority: must
  stability: stable

- id: editor.step_config.req_subnode_type_filter
  statement: When adding a subnode to an input, the AddStepPicker is filtered to only show step types matching the input's `accepts.type_ids`.
  priority: must
  stability: stable

- id: editor.step_config.req_three_pane_layout
  statement: The config modal has three panes — Config (schema-driven fields), Context (upstream data explorer), and Output (execution results and pinned outputs).
  priority: must
  stability: stable

- id: editor.step_config.req_dirty_tracking
  statement: The config composable tracks `hasUnsavedChanges` by comparing working field values against original values. Unsaved changes are shown with a discard option.
  priority: must
  stability: stable

- id: editor.step_config.req_config_schema_stability
  statement: All step executors must define a JSON Schema-compatible `config_schema`. Free-form config without a schema is not supported.
  priority: must
  stability: stable
~~~

## Scenarios

~~~spec-scenarios
- id: editor.step_config.scenario_expression_preview
  given:
    - Step "Send Email" has a `text` field in expression mode
    - Upstream step "Fetch Orders" has a pinned output with `{body: {name: "Alice"}}`
  when:
    - The user types `Hello {{ steps.fetch_orders.body.name }}` and 300ms elapses
  then:
    - A preview request is sent to the server
    - The server evaluates the expression with the pinned output as context
    - The preview result `Hello Alice` is displayed below the field
  covers:
    - editor.step_config.req_expression_preview_debounced
    - editor.step_config.req_preview_context_assembly
~~~

## Verification

~~~spec-verification
- kind: source_file
  target: assets/vue/composables/workflow/useStepConfig.ts
  covers:
    - editor.step_config.req_schema_driven_fields
    - editor.step_config.req_field_type_precedence
    - editor.step_config.req_expression_mode_toggle
    - editor.step_config.req_dirty_tracking

- kind: source_file
  target: lib/fizz/workflows/expressions.ex
  covers:
    - editor.step_config.req_expression_preview_debounced
    - editor.step_config.req_preview_context_assembly
~~~
