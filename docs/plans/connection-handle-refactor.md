# Connection Handle Refactor Plan

Status date: 2026-05-27

This plan replaces the current subnode-specific declaration and compiler path with a
single connection-handle model built on the primitives Fizz already has:
`@fields`, `@input_schema`, `@output_schema`, and workflow connections with
`source_output` / `target_input`.

## Executive Summary

Subnodes should not be a second graph system. Model nodes, schema nodes, and tool
nodes are regular nodes. What is special is the target handle they connect to: an
AI Agent `model` input is a dependency handle, while a normal `main` input is a
flow handle.

The final state removes:

- `@subnode_inputs`
- `role: :subnode` as a compiler invariant
- root-specific "subnode ownership" validation in the assembler
- client assumptions that `node_role === "subnode"` determines layout or wiring

The replacement is:

- target input handles declared in `@input_schema`
- source output handles declared in `@output_schema`
- one workflow/compiler connection validation stage for all connections
- dependency rendering inferred from connection metadata, not from a second
  subnode API

## Current Problems

### Subnode Inputs Are A Parallel Declaration System

`Fizz.Integrations.Steps.Definition` currently supports `@fields`,
`@input_schema`, `@output_schema`, and `@subnode_inputs`. The first three are
general step metadata. `@subnode_inputs` is a raw map format used only by root
nodes like `ai_agent`.

The assembler then treats `target_input != "main"` as a special subnode path and
validates that the source step has `node_role == :subnode`. This makes secondary
inputs a separate system even though workflow connections already have
`source_output` and `target_input`.

Relevant files:

- `lib/fizz/integrations/steps/definition.ex`
- `lib/fizz/integrations/steps/type.ex`
- `lib/fizz/integrations/library/fizz/builtins/ai_agent.ex`
- `lib/fizz/workflows/compiler/assembler.ex`
- `lib/fizz/workflows/embeds/connection.ex`

### Fields Are Correctly Config-Only

`Fizz.Fields` is the source of truth for persisted step configuration fields.
It generates `config_schema`, `default_config`, and per-field renderer metadata.

Field metadata such as `component`, `display`, `resolver`, `resource_locator`,
and `resource_mapper` belongs to `Fizz.Fields.Definition` and is emitted into
`config_schema` as adapter output. It should not be reused for graph topology.

Relevant files:

- `lib/fizz/fields/definition.ex`
- `lib/fizz/fields.ex`
- `assets/vue/types/configSchema.ts`
- `assets/vue/components/flow/step_config/useStepConfig.ts`

## Design Goals

- Keep one workflow connection primitive: `source_step_id`, `source_output`,
  `target_step_id`, and `target_input`.
- Keep `@fields` strictly for persisted node config and field rendering.
- Declare connection handles with existing step schemas, not a new public
  `Port`, `SubnodeInput`, or `OutputCapability` primitive.
- Make subnode-like attachments regular nodes connected to dependency handles.
- Validate all connection handles through one server-side path.
- Keep the assembler focused on Runic wiring, not authored graph validation.
- Use provider-neutral AI output contracts without adding a top-level `Fizz.AI`
  namespace.
- Prefer a hard cutover over compatibility shims. Update declarations,
  compiler, runtime, editor, and tests together; do not preserve old subnode
  semantics.

## Non-Goals

- Do not introduce a new top-level `Fizz.AI` context.
- Do not add a second field system for connected inputs.
- Do not put field `ui` metadata in `@input_schema`.
- Do not keep backwards-compatibility shims in the final state.
- Do not make provider dispatch in `AIAgent` depend on a hardcoded provider list.

## Decisions Before Implementation

- Primary executor input key is `"main"`, not `"_primary"`. `AIAgent` should be
  updated in the same cutover to read `input["main"]`. The old `_primary` key
  should not be preserved as a convention.
- AI model matching uses `provides: ["ai.chat_model"]`, not the broader
  `ai.model`. Tool and structured schema matching use `ai.tool` and
  `ai.schema`.
- The old `accepts.type_ids` check is deleted and replaced by semantic
  `accepts.provides`. There is no adapter that translates type IDs to
  capabilities.
- Dependency source nodes may be used in normal flow if their output shape is
  otherwise valid. Product UX can present them as attached helpers, but compiler
  rules are handle-based.
- Publish/compile validation is authoritative. Draft-time validation should use
  the same validator when step type and compiled-config context is available,
  but draft operations can remain syntactic where full context is unavailable.

## Core Concepts

### Config Fields

Config fields are persisted settings on a step. They are declared with
`Fizz.Fields` and become `config_schema` and `default_config`.

Example:

```elixir
@fields [
  Fields.string("system_prompt",
    label: "System Prompt",
    format: "textarea",
    default: "You are a helpful assistant."
  )
]
```

These are rendered in the step config UI and saved into the workflow definition.

### Input Handles

Input handles are graph targets. They are declared in `@input_schema` because
they describe what runtime input the executor can receive from upstream nodes.

A handle can be:

| Kind | Meaning |
|---|---|
| `flow` | Primary workflow data dependency. Participates in normal lineage, split/join, and terminal-step behavior. |
| `dependency` | Secondary dependency used by the target executor. Does not make the source node a normal flow parent. |

Input handle metadata lives directly on the relevant input schema property under
the `"connection"` key. This follows the current field schema style, where Fizz
metadata such as `"display"` and `"resource_mapper"` is direct schema metadata
instead of being nested under a namespaced extension object.

### Output Handles

Output handles are graph sources. The default output handle is `main`, backed by
`@output_schema`.

Most steps do not need to declare output handles explicitly. If no metadata is
present, the step has one `main` flow output.

Steps that produce a semantic value for dependency inputs declare `"provides"`.
Steps with multiple output handles, such as Condition and Switch, declare
`"outputs"`.

## Schema Shape

### Target Input Handle

```elixir
@input_schema %{
  "type" => "object",
  "required" => ["model"],
  "properties" => %{
    "main" => %{
      "title" => "Input",
      "description" => "Primary flow input",
      "connection" => %{
        "kind" => "flow"
      }
    },
    "model" => %{
      "title" => "Model",
      "description" => "LLM model provider",
      "connection" => %{
        "kind" => "dependency",
        "cardinality" => "one",
        "accepts" => %{"provides" => ["ai.chat_model"]}
      }
    },
    "structured_schema" => %{
      "title" => "Structured Schema",
      "description" => "Optional structured response schema",
      "connection" => %{
        "kind" => "dependency",
        "cardinality" => "one",
        "accepts" => %{"provides" => ["ai.schema"]}
      }
    },
    "tools" => %{
      "title" => "Tools",
      "description" => "Optional tool descriptors",
      "type" => "array",
      "items" => %{"type" => "object"},
      "connection" => %{
        "kind" => "dependency",
        "cardinality" => "many",
        "accepts" => %{"provides" => ["ai.tool"]}
      }
    }
  }
}
```

Rules:

- Property key is the executor input key.
- `connection.handle` defaults to the property key.
- Required handles are read from the schema `"required"` list.
- `cardinality` defaults to `one`.
- `accepts.provides` validates against the source output handle's `"provides"`.

### Source Output Contract

```elixir
@output_schema %{
  "type" => "object",
  "provides" => ["ai.chat_model"],
  "properties" => %{
    "kind" => %{"const" => "ai.chat_model"},
    "provider" => %{"type" => "string"},
    "credential_ref" => %{"type" => "object"},
    "model_spec" => %{"type" => "string"},
    "temperature" => %{"type" => "number"},
    "max_tokens" => %{"type" => "integer"},
    "capabilities" => %{"type" => "array", "items" => %{"type" => "string"}}
  },
  "required" => ["kind", "provider", "credential_ref", "model_spec"]
}
```

Rules:

- Top-level `"provides"` applies to the default `main` output.
- Runtime output should include `"kind"` with the same semantic value, such as
  `"ai.chat_model"`, so root executors can pattern-match/normalize defensively.
- Source/target matching is declaration-time metadata; runtime validation can
  still assert the produced value has the expected `"kind"`.

### Multiple Output Handles

```elixir
@output_schema %{
  "description" => "Pass-through branch outputs",
  "outputs" => [
    %{"id" => "main", "kind" => "flow"},
    %{"id" => "true", "kind" => "flow", "config_key" => "true_output"},
    %{"id" => "false", "kind" => "flow", "config_key" => "false_output"}
  ]
}
```

Rules:

- `outputs` declares named `source_output` handles.
- `config_key` means the authored handle is derived from compiled config.
- `dynamic_outputs_from` means handles are enumerated from compiled config.
- Condition and Switch output handles must be resolved after expression
  compilation, when their config values are literal strings.

Switch cannot use `config_key` for case outputs because it has an arbitrary
number of user-authored cases. It declares a dynamic output source:

```elixir
@output_schema %{
  "description" => "Input data routed through matching case output",
  "outputs" => [
    %{"id" => "main", "kind" => "flow"},
    %{"id" => "default", "kind" => "flow", "config_key" => "default_output"},
    %{"kind" => "flow", "dynamic_outputs_from" => "cases[].output"}
  ]
}
```

The connection planner resolves `dynamic_outputs_from` against compiled config,
deduplicates repeated handle names, and rejects non-string or empty output names.

## Step Examples

### AI Agent

`AIAgent` keeps normal config in `@fields`:

```elixir
@fields [
  Fields.select("mode",
    label: "Execution Mode",
    default: "assemble_only",
    options: Fields.options(~w(assemble_only provider_chat))
  ),
  Fields.string("system_prompt",
    label: "System Prompt",
    format: "textarea",
    default: "You are a helpful assistant."
  ),
  Fields.string("user_message",
    label: "User Message",
    format: "textarea",
    required?: true,
    default: "{{ json }}"
  )
]
```

Connected model/schema/tool values move to `@input_schema` properties with
`connection` metadata. `@subnode_inputs` is removed.

`AIAgent.execute/3` receives:

```elixir
%{
  "main" => primary_input,
  "model" => %{"kind" => "ai.chat_model", ...},
  "structured_schema" => %{"kind" => "ai.schema", ...} | nil,
  "tools" => [%{"kind" => "ai.tool", ...}]
}
```

### OpenAI Model

The OpenAI model node becomes a regular transform node. It should not rely on
`role: :subnode` for compiler behavior.

Its `@fields` remain credential/model settings. Its `@output_schema` declares
that `main` provides `ai.chat_model`. Its runtime output is a string-keyed
tagged map:

```elixir
%{
  "kind" => "ai.chat_model",
  "provider" => "openai_api_key",
  "credential_ref" => credential_ref,
  "model_spec" => "openai:" <> model,
  "temperature" => temperature,
  "max_tokens" => max_tokens,
  "capabilities" => ["chat", "structured_output", "tools"]
}
```

### Structured Schema

The structured schema node declares `@output_schema["provides"] == ["ai.schema"]`
and returns:

```elixir
%{
  "kind" => "ai.schema",
  "name" => name,
  "schema" => schema,
  "response_format" => response_format
}
```

Shared schema unwrapping and response-format construction should be extracted
only if it is used by multiple builtins. The natural home is near the Fizz
builtin AI nodes, not top-level `Fizz.AI`.

### HTTP Tool

The HTTP tool node declares `@output_schema["provides"] == ["ai.tool"]` and
returns:

```elixir
%{
  "kind" => "ai.tool",
  "type" => "http",
  "name" => name,
  "description" => description,
  "request" => request
}
```

### Condition

Condition should expose configured branch handles as normal output handles:

```elixir
@output_schema %{
  "description" => "Input data routed through configured branch outputs",
  "outputs" => [
    %{"id" => "main", "kind" => "flow"},
    %{"id" => "true", "kind" => "flow", "config_key" => "true_output"},
    %{"id" => "false", "kind" => "flow", "config_key" => "false_output"}
  ]
}
```

### Switch

Switch should expose:

- `main`
- compiled `default_output`
- each compiled `cases[].output`, declared via
  `dynamic_outputs_from: "cases[].output"`

Duplicate case output names remain valid and should continue to union into a
single authored output handle.

## Compiler Design

### New Internal Stage

Add one internal compiler stage, not a public declaration primitive:

```elixir
Fizz.Workflows.Compiler.ConnectionPlan
```

This stage runs after expression compilation and before Runic assembly:

```elixir
with {:ok, ir} <- Normalizer.normalize(version),
     {:ok, ir} <- ExpressionCompiler.compile_expressions(ir),
     {:ok, ir} <- ConnectionPlan.build(ir),
     {:ok, workflow} <- Assembler.assemble(ir, opts),
     {:ok, hash} <- compute_hash(ir) do
  {:ok, workflow, hash}
end
```

It owns semantic connection validation for both flow and dependency handles.

### IR Contract

`ConnectionPlan.build/1` does not rewrite `ir.connections`. It validates them
and attaches a parallel `connection_plan` map:

```elixir
%{
  connections: %{
    connection_id => %{
      id: connection_id,
      source_step_id: source_step_id,
      source_output: source_output,
      target_step_id: target_step_id,
      target_input: target_input,
      order: non_neg_integer(),
      kind: :flow | :dependency,
      source_handle: %{
        id: source_output,
        kind: :flow | :dependency,
        provides: ["ai.chat_model"]
      },
      target_handle: %{
        id: target_input,
        key: "model",
        kind: :flow | :dependency,
        cardinality: :one | :many,
        required?: boolean(),
        accepts: %{provides: ["ai.chat_model"]}
      }
    }
  },
  by_target_step: %{
    target_step_id => %{
      flow: [connection_id],
      dependencies: %{
        target_input => [connection_id]
      }
    }
  },
  by_source_step: %{
    source_step_id => [connection_id]
  },
  required_dependencies: %{
    target_step_id => MapSet.t(target_input)
  }
}
```

After Slice 2, `connection_plan` is the exclusive connection semantics contract
for the assembler. `ir.connections` may remain on the IR as source data for
debugging or hashing, but assembler code should not inspect it to classify
connections, resolve handles, check required inputs, check cardinality, or infer
ordering.

Assembler consumes `ir.connection_plan.by_target_step` when resolving parents.
Flow connections participate in lineage, joins, terminal-step detection, and
normal parent refs. Dependency connections are wired as parents only for the
target executor input assembly and do not affect flow terminal-step detection.

For `cardinality: :many`, dependency values are ordered by authored connection
order captured as `order` in the planned connection. This preserves user intent
and gives tool arrays a deterministic order without making the assembler read
raw connection records. The editor should preserve that order when it rewrites
connection lists.

### ConnectionPlan Responsibilities

- Resolve each `source_output` to a source output handle.
- Resolve each `target_input` to a target input handle.
- Reject unknown source handles.
- Reject unknown target handles.
- Validate `kind` matching where required.
- Validate `accepts.provides` against source output `"provides"`.
- Validate dependency cardinality.
- Validate required dependency handles.
- Group incoming connections by target handle.
- Mark each edge as `flow` or `dependency`.
- Produce a plan the assembler can consume without re-validating user-authored
  graph semantics.

### Assembler Responsibilities

Keep:

- Build Runic components.
- Map planned source handles to concrete Runic refs.
- Insert union passthroughs when one authored output handle maps to multiple
  concrete branch refs.
- Preserve split/join/aggregator lineage semantics for flow edges.
- Assemble dependency values into the target executor input map.
- Read planned connection groups and planned connection metadata from
  `ir.connection_plan` only.

Remove:

- `normalize_subnode_input_defs/1`
- source `node_role == :subnode` validation
- subnode ownership validation
- required/cardinality checks specific to subnodes
- `target_input != "main"` as the definition of a subnode connection

## Runtime And AI Provider Dispatch

Provider dispatch should not live in `AIAgent` as a provider-id `case`.

The model node should emit a provider-qualified model spec, credential ref, and
capabilities. `AIAgent` builds a provider-neutral request and delegates execution
to a generic AI runner close to the Fizz builtins or integration support layer.

OpenAI-specific clients can remain under `Fizz.Integrations.Library.OpenAI` for
OpenAI-specific actions, but the root AI Agent should not have to change when a
new chat model provider is added.

The concrete dispatch mechanism is a registry, not a protocol and not a
pattern-match in `AIAgent`.

`Fizz.Integrations.Library.Fizz.Builtins.AIChatRunner` is the facade called by
`AIAgent`. Provider-specific modules implement a small behaviour and are indexed
by `model_spec` prefix:

```elixir
defmodule Fizz.Integrations.Library.Fizz.Builtins.AIChatRunner.Provider do
  @callback provider_prefix() :: String.t()
  @callback generate(request :: map(), context :: map()) ::
              {:ok, map()} | {:error, term()}
end
```

Example provider modules:

- `Fizz.Integrations.Library.OpenAI.ChatModelRunner` returns
  `provider_prefix() == "openai"`.
- `Fizz.Integrations.Library.Anthropic.ChatModelRunner` returns
  `provider_prefix() == "anthropic"`.

The registry is loaded at application startup, following the same shape as the
existing integration registries: built-in runner modules come from a generated
catalog/manifest function, and tests can replace that list through config. The
registry rejects duplicate prefixes and unknown modules at startup.

`AIAgent` calls one runner with:

```elixir
%{
  "model" => %{
    "kind" => "ai.chat_model",
    "provider" => "openai_api_key",
    "credential_ref" => credential_ref,
    "model_spec" => "openai:gpt-5.5",
    "capabilities" => ["chat", "structured_output"]
  },
  "messages" => messages,
  "structured_schema" => schema,
  "tools" => tools
}
```

`AIChatRunner.generate/2` parses the provider prefix from `"model_spec"`, looks
up the provider module in `AIChatRunner.Registry`, and delegates the request to
that module. The provider runner resolves credentials from `"provider"` and
`"credential_ref"` and calls the underlying LLM client.

Adding a provider means adding a model node that emits a valid model spec,
adding a provider runner module, and registering it in the generated catalog. It
does not require editing `AIAgent`, and the model output remains plain data
rather than carrying an Elixir module atom.

## Frontend Design

The editor should stop using `node_role === "subnode"` as the rendering rule.
Visual subnodes are a presentation of dependency edges, not a backend step role.

### Handle Catalog

The step type catalog sent to the editor must include enough schema data to
build the same handle catalog the compiler sees:

- input handles from `@input_schema` properties with `connection` metadata
- dependency target handles where `connection.kind == "dependency"`
- flow target handles where `connection.kind == "flow"`, including `"main"`
- output handles from `@output_schema.outputs`, with `main` as the default
- source capabilities from top-level or per-output `"provides"`

The frontend can derive this from raw schemas or consume normalized handle
metadata on the `StepType` payload. The final behavior should not depend on
`subnode_inputs` or `node_role`.

### Visual Node Classification

`assets/vue/components/flow/Node.vue` remains the full step card. It renders:

- a left target handle for the `"main"` flow input
- a right source handle for the `"main"` flow output
- bottom target handles for dependency inputs discovered from
  `connection.kind == "dependency"`
- normal step controls such as run, disable, pin, validation, status, and stats

`assets/vue/components/flow/SubNode.vue` remains the compact attached-node
presentation. It renders:

- the compact icon/squarcle and small editable label
- a top `"main"` source handle that connects upward to the parent dependency
  handle
- status dot and selection styling
- no left flow target, no bottom dependency targets, and no run/disable/pin
  controls

The same step type can render through either component. A model step that is not
the source of a dependency edge renders as `Node.vue`; the same model step
renders as `SubNode.vue` when the current graph connects its `main` output into
another step's dependency input. This is recomputed from the connection graph
whenever nodes and edges are built.

There is no persisted node type, persisted subnode flag, or backend
`role: :subnode` involved in this visual decision. Quick-add may create a step
and a dependency connection in one interaction, but the saved workflow still
only contains regular steps and regular connections.

The frontend computes that rendering from connections:

1. Build a handle catalog per step type.
2. For each edge, look up the target step type and `target_input`.
3. If the target handle is `kind: "dependency"`, classify the edge as a
   dependency edge.
4. A source node connected into a dependency edge becomes an attached dependency
   node and is rendered with Vue Flow `type: "subnode"`.
5. Other nodes render with Vue Flow `type: "step"`.

This replaces the current `useWorkflowNodes.ts` rule:

```ts
const isSubnode = stepType?.node_role === 'subnode';
```

with a connection-derived rule:

```ts
const isAttachedDependency = attachedDependencySourceIds.has(step.id);
```

Layout should use the same dependency-edge classification. `useLayout.ts`
currently treats `targetHandle !== "main"` and `node.type === "subnode"` as the
attached subtree signal. After the cutover, it should use handle metadata:

```ts
const isDependencyEdge = dependencyEdgeIds.has(edge.id);
```

Quick-add filtering changes the same way. The current
`mode: "subnode_input"` / `accepted_type_ids` filter becomes a dependency-input
filter based on `accepts.provides`, and the palette includes any step type whose
selected output provides the required capability.

The frontend can optimistically validate handle compatibility, but server-side
validation remains authoritative.

Relevant current files:

- `assets/vue/composables/useWorkflowNodes.ts`
- `assets/vue/components/flow/Node.vue`
- `assets/vue/components/flow/step_config/useSubnodes.ts`
- `assets/vue/lib/useLayout.ts`
- `assets/vue/types/workflow.ts`

## Validation Boundaries

### Step Registry

`Fizz.Integrations.Steps.Registry` should validate declaration shape:

- connection metadata is a map
- handle IDs are non-empty strings
- handle kinds are supported
- cardinality is `one` or `many`
- `accepts.provides` and `provides` are lists of strings
- required handles correspond to schema properties
- no duplicate static output handles

This validation should run when the step registry loads step modules at
application startup. Invalid declaration metadata should fail startup with a
clear error, matching the existing catalog guardrail pattern.

### Draft Operations

`Fizz.Workflows.DraftSession.Operation` can keep cheap syntactic checks:

- source step exists
- target step exists
- no self-edge
- no duplicate edge

It should call shared connection-handle validation when enough step type/config
context is available. Otherwise, publish/compile validation remains the final
authority.

### Publish And Compile

Publish/compile validation must run the full `ConnectionPlan` checks. A workflow
with an unknown handle, missing required dependency, or incompatible dependency
must not publish or compile.

## Implementation Cutover

This is a hard cutover. The branch should replace the old subnode declaration
and compiler path in place, update all affected tests, and leave no compatibility
adapter behind.

### Slice 1 - Read Schema Handles

- Add schema readers that derive input handles from `@input_schema`.
- Add schema readers that derive output handles from `@output_schema`.
- Default missing input/output metadata to normal `main` flow handles.
- Add registry validation for the new metadata.
- Resolve all implementation-gating schema decisions in this slice: handle names,
  `provides` values, dynamic output metadata, and draft-time validation scope.

### Slice 2 - Connection Plan

- Add `Fizz.Workflows.Compiler.ConnectionPlan`.
- Move unknown handle, required handle, cardinality, and capability checks out
  of assembler.
- Attach planned flow/dependency groups to the IR.
- Update tests for invalid target handles. The current draft-session behavior
  that allows arbitrary non-main `target_input` should become invalid unless the
  target declares the handle.

### Slice 3 - Convert AI Nodes

- Replace `AIAgent.@subnode_inputs` with `@input_schema` connection metadata.
- Remove `role: :subnode` from OpenAI model, Anthropic model, structured schema,
  and HTTP tool nodes.
- Add `"provides"` metadata and `"kind"` runtime output tags to model/schema/tool
  nodes.
- Change `AIAgent.execute/3` to read primary input from `"main"`, not
  `"_primary"`.
- Replace `AIAgent` provider-id dispatch with a generic model request runner.
- Extract duplicated structured schema helpers only if still duplicated after the
  value shape is normalized.

### Slice 4 - Convert Branch Handles

- Add output handle metadata for Condition and Switch.
- Move branch-handle validation out of assembler.
- Preserve current union behavior for duplicate switch outputs.

### Slice 5 - Update Editor

- Replace `subnode_inputs` and `node_role === "subnode"` rendering logic with
  input handle metadata.
- Render dependency handles from `connection.kind == "dependency"`.
- Filter connectable nodes by `accepts.provides`.
- Remove subnode-specific Vue types and composables once the handle metadata path
  is complete.

### Slice 6 - Delete Old Primitives

- Delete `@subnode_inputs` support from `StepDefinition`.
- Delete `subnode_inputs` from `StepType`.
- Delete `node_role` if no remaining non-rendering use survives review.
- Delete assembler subnode helper functions.
- Bump compiler version.
- Update design docs that still describe roles/subnodes as separate primitives.

## Testing Plan

Backend:

- Step definition tests for schema-derived input/output handles.
- Registry guardrail tests for invalid connection metadata.
- Registry guardrail tests for `dynamic_outputs_from` declaration shape.
- Compiler tests for missing required dependency handles.
- Compiler tests for cardinality violations.
- Compiler tests for incompatible `accepts.provides`.
- Compiler tests for unknown `source_output` and `target_input`.
- Existing AI Agent assembly tests rewritten for regular dependency handles.
- Existing Condition/Switch output routing tests preserved.
- Switch tests for dynamic `cases[].output`, duplicate output union behavior, and
  invalid non-string output names.
- Draft operation tests updated for semantic handle validation.

Frontend:

- Node rendering tests for dependency handles.
- Edge interaction tests for source/target handles.
- Layout tests for attached dependency nodes.
- Step config tests confirming field `ui` still comes only from `config_schema`.

Full validation:

```sh
mix test test/fizz/integrations/connection_handle_metadata_test.exs
mix test test/fizz/workflows/compiler_test.exs
mix test test/fizz/workflows/draft_session_test.exs
mix test test/fizz_web/live/workflow_editor_live_test.exs
mix assets.build
mix precommit
```

## Open Questions

- Should connection handle metadata be derived directly from raw schemas in each
  compiler phase, or normalized once into cached metadata on `StepType`?
- Should runtime output `"kind"` validation be enforced for all dependency
  connections, or only for AI values during the first implementation slice?
- Do dependency edges need their own display ordering field later, or is authored
  connection order sufficient?

## Decision Summary

Use schemas as the declaration surface, fields as config only, and connections as
the single graph primitive.

The connection layer should become capable enough to validate and assemble both
normal flow edges and dependency edges. Subnodes then become an editor
presentation of dependency handles, not a separate backend concept.
