# 4. Step Configuration

## Context

Step configuration is the core authoring experience. Each step type declares a `config_schema` (JSON Schema + `"ui"` extension) that drives the config modal. The POC has a working schema-driven renderer in `StepConfigConfigPane.vue` with `useStepConfig.ts`. This document defines the production step configuration system.

---

## Config Schema System

### Backend Definition (exists)

Each executor module defines its config schema:

```elixir
# Example: lib/fizz/steps/executors/slack_send_message.ex
@config_schema %{
  "type" => "object",
  "required" => ["channel_id", "text"],
  "properties" => %{
    "channel_id" => %{
      "type" => "string",
      "title" => "Channel",
      "description" => "Channel ID, user ID, or email"
    },
    "text" => %{
      "type" => "string",
      "title" => "Message Text",
      "format" => "textarea"
    },
    "credential_ref" => %{
      "type" => "object",
      "title" => "Credential",
      "ui" => %{
        "component" => "select",
        "resolver" => "Fizz.Integrations.CredentialsResolver",
        "params" => %{"provider_filter" => ["slack_oauth"]}
      }
    }
  }
}
```

### Field Type Inference (exists in `useStepConfig.ts`)

The composable already maps JSON Schema → UI field type:

| Schema Pattern | UI Field Type |
|---------------|---------------|
| `ui.component === "search"` | Search (resolver-driven autocomplete) |
| `ui.component === "select"` | Select dropdown |
| `enum` present | Select dropdown |
| `format === "json"` | JSON editor |
| `format === "textarea"` | Multi-line textarea |
| `type === "number" \| "integer"` | Number input |
| `type === "boolean"` | Boolean toggle |
| `type === "object"` (no ui) | Nested object (JSON fallback) |
| Default | Text input |

### Config Schema TypeScript Types (exists in `types/configSchema.ts`)

```typescript
interface ConfigSchemaField {
  title?: string;
  type?: string;
  format?: string;
  default?: unknown;
  enum?: unknown[];
  description?: string;
  required?: string[];
  properties?: Record<string, ConfigSchemaField>;
  ui?: FieldUIConfig;
}

interface FieldUIConfig {
  component?: 'select' | 'search' | string;
  resolver?: string;
  params?: Record<string, unknown>;
  options?: Array<{ value: string; label: string }>;
  responseConfig?: { valueKey?: string; labelKey?: string };
}
```

---

## Config Modal Architecture

### Three-Pane Layout (exists in `StepConfigModal.vue`)

```
┌──────────────────────────────────────────────────────┐
│  Step Name (inline editable)          [X Close]       │
├────────────┬───────────────┬─────────────────────────┤
│ Config     │ Context       │ Output                   │
├────────────┴───────────────┴─────────────────────────┤
│                                                       │
│  [Active pane content]                                │
│                                                       │
│  Config: Schema-driven field editor                   │
│  Context: Upstream data explorer                      │
│  Output: Step execution results + pinned outputs      │
│                                                       │
├───────────────────────────────────────────────────────┤
│  [Save Configuration]    [Discard] (if unsaved)       │
└───────────────────────────────────────────────────────┘
```

### State Management (`useStepConfig.ts` — exists, keep)

```typescript
// Core state
fieldModes: Record<string, 'literal' | 'expression'>  // per-field mode
fieldValues: Record<string, unknown>                    // working copy
originalValues: Record<string, unknown>                 // for dirty tracking
hasUnsavedChanges: computed                              // fieldValues !== originalValues

// Sub-composables
useExpressionPreviews()    // debounced preview requests
useExpressionHelpers()     // variable autocomplete data
useContextExplorer()       // upstream step output tree
useSubnodes()              // subnode input management
useStepExecution()         // execution data for this step
usePinnedOutputs()         // pinned output data
useInputData()             // resolved input from upstream
```

---

## Expression Editing

### Expression Mode Toggle (exists)

Each field has a "Fixed" / "Expression" toggle. When in expression mode:
- The field input becomes a text area for `{{ }}` or `{% %}` syntax
- Auto-detection: if a field value contains `{{` or `{%`, auto-switch to expression mode

### Expression Syntax Highlighting (new)

**Approach:** Integrate a lightweight code editor for expression fields.

**Option A (recommended for v1):** Custom syntax highlighting via a `<textarea>` with a mirrored overlay that applies CSS classes to `{{ }}`, `{% %}`, filter names, and variable paths. Lightweight, no heavy dependency.

**Option B (future):** CodeMirror 6 with a custom Liquid/Solid language grammar. Full IDE experience with bracket matching, error underlining, etc. Heavier but more capable.

For v1, go with Option A. The expression language is simple enough that regex-based highlighting covers the common cases.

### Variable Autocomplete (new — partially exists)

`useExpressionHelpers` already computes available variables from upstream step output schemas. Wire this into an autocomplete dropdown:

**Trigger:** When the user types `{{ steps.` or `{{ input.` in an expression field.

**Data source:**
1. `steps.*` — iterate upstream steps (from `useWorkflowGraph.stepOrderById`), show each step's output schema fields
2. `input.*` — current step's input schema fields
3. `workflow.*` — workflow metadata fields
4. `env.*` — platform-injected values

**Autocomplete item format:**
```
{{ steps.fetch_orders          → Step: "Fetch Orders" (http_request)
{{ steps.fetch_orders.body     → Output field: body (object)
{{ steps.fetch_orders.status   → Output field: status (integer)
{{ input.customer_id           → Input field: customer_id (string)
```

**Implementation:** A floating dropdown positioned relative to the cursor in the expression textarea. Filter items as the user types. Insert the selected path on Enter/click.

### Live Expression Preview (exists — needs backend)

`useExpressionPreviews` debounces changes (300ms) and emits `preview_expression` to the server. The server needs to evaluate the expression and return a result.

**New backend contract:**
```elixir
# Fizz.Workflows.Expressions (new module)
@spec preview(String.t(), map()) :: {:ok, term()} | {:error, String.t()}
def preview(expression, context) do
  case Solid.parse(expression) do
    {:ok, template} ->
      case Solid.render(template, context) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, inspect(reason)}
      end
    {:error, reason} ->
      {:error, "Parse error: #{inspect(reason)}"}
  end
end
```

**Context assembly** (in the LiveView):
```elixir
context = %{
  "steps" => build_upstream_context(step_id, draft, editor_state),
  "input" => build_input_context(step_id, draft, step_executions),
  "workflow" => %{"id" => definition.id, "name" => definition.name},
  "env" => %{}  # platform values
}
```

Where `build_upstream_context` gathers:
1. Pinned outputs from `editor_state.pinned_outputs` (preferred)
2. Last execution outputs from `step_executions` (fallback)
3. Empty placeholders with schema shape (if no data available)

---

## Credential Selection

### Resolver-Driven Search (exists)

The `SearchField.vue` component handles resolver-driven fields. When `ui.component === "search"`:
1. Component shows a search input with dropdown
2. On search query, emits to LiveView
3. LiveView calls `CredentialsResolver.search(scope, params)` with provider filter
4. Returns `[%{id, provider, display_name, auth_type, owner_display_name}]`
5. Component displays results for selection

**Pre-loading:** On mount, the LiveView pre-loads credential options for common providers used by the draft's step types. Stored in `credential_options` assign.

**Lazy loading:** For less common providers, credentials are fetched on-demand when the config modal opens for that step type.

---

## Subnode Slot Management (exists)

Root steps can declare `subnode_inputs`:
```elixir
subnode_inputs: [
  %{id: "model", title: "Model", required: true, cardinality: :one,
    accepts: %{type_ids: ["openai_model", "anthropic_model"]}},
  %{id: "tools", title: "Tools", required: false, cardinality: :many,
    accepts: %{type_ids: ["ai_tool"]}}
]
```

The `useSubnodes` composable:
- Shows occupied/empty input indicators in the config pane
- Empty inputs show "Add [input_title]" button → opens AddStepPicker filtered by `accepts.type_ids`
- Occupied inputs show the connected subnode step name with a link to its config
- Input cardinality `:one` prevents multiple connections; `:many` allows multiple

---

## Validation Errors

### Draft-Time Warnings (new — display only, non-blocking)

Shown as yellow indicators on steps and fields while editing:
- Missing required config fields (from `config_schema.required`)
- Unresolved credential references
- Disconnected steps (no inputs or outputs, excluding trigger roots)
- Unknown variables in expressions (reference to non-existent upstream step)

**Implementation:** Run lightweight client-side validation in `useStepConfig` whenever `fieldValues` change. No server round-trip needed for basic schema validation.

### Publish-Time Errors (exists — needs structured format)

Shown as red indicators, blocking publish:
- All draft-time checks (strict mode)
- Expression parse errors
- Expression filter validation (only allowed filters)
- Expression step reference validation (referenced steps exist and are upstream)
- Credential accessibility (credential exists and user has access)
- Step config executor validation (`validate_config/1`)

**New backend contract:**
```elixir
@spec validate_for_publish(WorkflowDefinitionVersion.t(), Scope.t()) ::
  :ok | {:error, [ValidationError.t()]}

@type ValidationError.t() :: %{
  step_id: String.t() | nil,     # nil for global errors
  field: String.t() | nil,       # nil for step-level errors
  message: String.t(),
  severity: :error | :warning
}
```

**Display in config modal:** Field-level errors show red border + error message below the input. Step-level errors show in a collapsible error section at the top of the config pane.

**Display on canvas:** Steps with errors show a red badge/border. Hovering shows error summary tooltip.

---

## Upstream Context Inspection (exists)

### Context Pane (`StepConfigContextPane.vue`)

Shows what data is available to this step from upstream:
- Tree view of upstream step outputs (from execution data or pinned outputs)
- Click to copy variable path (e.g., `{{ steps.fetch_orders.body.orders[0].id }}`)
- Schema-based preview when no execution data is available

### Data Viewer Components (exists)

- `DataViewer.vue` — tab switcher (JSON / Tree)
- `DataViewerJson.vue` — formatted JSON with syntax highlighting
- `DataViewerTree.vue` — expandable tree with type badges
- `TreeNodeRow.vue` — individual tree row with copy-path button

---

## What Exists vs. What's New

**Exists (keep):**
- `StepConfigModal.vue` — 3-pane layout
- `StepConfigConfigPane.vue` — schema-driven field rendering
- `StepConfigContextPane.vue` — upstream data explorer
- `StepConfigOutputPane.vue` — execution results viewer
- `useStepConfig.ts` — core state management composable
- `FieldWrapper.vue`, `StringField.vue`, `NumberField.vue`, `SelectField.vue`, `SearchField.vue`
- `useExpressionPreviews` — debounced preview requests
- `useExpressionHelpers` — variable data computation
- `useContextExplorer` — upstream context tree
- `useSubnodes` — subnode input management
- `usePinnedOutputs`, `useInputData`, `useStepExecution`
- `DataViewer` component family
- Config schema TypeScript types

**New:**
- Expression syntax highlighting (v1: overlay-based; future: CodeMirror)
- Variable autocomplete dropdown
- `Fizz.Workflows.Expressions.preview/2` — backend preview API
- `Fizz.Workflows.validate_for_publish/2` — structured validation errors
- Client-side draft-time validation in `useStepConfig`
- Canvas error indicators (red badges on steps with errors)
- Publish modal validation display

---

## Assumptions

1. **Config schema stability:** All executors define JSON Schema-compatible `config_schema`. No free-form config without a schema.
2. **Expression security:** Solid/Liquid parser prevents arbitrary code execution. The preview API runs in a sandbox context with only step outputs and platform values available.
3. **Resolver latency:** Credential resolver queries return within 200ms. If external vault calls are slow, consider caching.
4. **Schema size:** Config schemas are small enough to push as props for all step types. If any executor has a very large schema, consider lazy-loading.
