# Compilation Pipeline, Expression System, and Workflow Context Design

**Status:** Proposed
**Date:** 2026-03-12
**Depends on:** durable-workflows-design.md, workflow-definition-design.md, expression-design-guide.md

---

## Overview

This document defines how an authored workflow definition becomes a running Runic workflow, how the Solid/Liquid expression system integrates with compilation and execution, and how workflow context is managed efficiently during durable execution.

Three foundational decisions anchor the design:

1. **Expressions resolve in Runic's Phase 1 (Prepare).** The prepare phase has full workflow access. We build the expression context from the fact graph, evaluate all expressions in the step's config, and pack the resolved config into `CausalContext.meta_context`. Phase 2 (Execute) receives fully-resolved config and runs the executor in isolation. This respects Runic's phase separation completely.

2. **Publish time produces a custom IR (Intermediate Representation).** A JSON-serializable, inspectable, migratable compiled artifact stored on the published version row. The runtime builds a Runic `%Workflow{}` from this IR on each execution start. This decouples the published artifact from runtime module versions and avoids re-parsing expressions on every start.

3. **Full context rebuild per step for v1.** On each prepare, walk all completed steps in the workflow and collect their output fact values into a map. This is O(N) where N is the number of completed steps, which is fine for realistic workflow sizes (< 100 steps). Dependency-scoped context (only resolving referenced steps) is a future optimization that also yields a free dependency graph.

---

## 1. Compilation Pipeline

Four phases with clear responsibility boundaries. Each phase narrows the space of possible errors so that later phases can assume more invariants.

### 1.1 Author Time (Draft Saves)

Responsibility: accept incomplete work, enforce structural invariants that the editor depends on.

What happens:

- Ecto `cast_embed` for steps, connections, step_groups
- Step IDs unique and key-safe
- Connection IDs unique
- Every `type_id` exists in `Fizz.Steps.Registry`
- Every connection references existing step IDs
- Every `step_group.step_ids` entry references an existing step
- A step belongs to at most one group
- The step graph is acyclic
- Viewport and settings accepted even if incomplete

What does NOT happen: expression parsing, config schema validation, credential resolution, topology analysis. Drafts may contain incomplete configs, dangling expression references, and missing credentials. Autosave must never reject partial work.

### 1.2 Publish Time (Draft -> Published)

Responsibility: prove the workflow is executable, produce the compiled IR.

This is the heavyweight phase. It runs a sequence of validations and transformations, each of which can produce user-facing errors. The sequence is ordered so that earlier checks establish invariants that later checks depend on.

```
validate_for_publish(version, scope)
  |> validate_structural_integrity()     # all save-time checks
  |> validate_step_configs()             # each config against its type's schema
  |> discover_and_parse_expressions()    # walk configs, parse Solid ASTs
  |> validate_expression_references()    # referenced step IDs exist, no forward deps
  |> validate_credentials(scope)         # credential refs resolve for current scope
  |> validate_handles()                  # source_output / target_input valid per type
  |> analyze_topology()                  # entry steps, fan-out regions, join points
  |> compile_to_ir()                     # produce CompiledWorkflow
  |> compute_compiled_hash()             # deterministic hash of the IR
  |> store_ir()                          # persist on the published version row
```

#### Expression discovery

Walk every step's config map recursively. For each string value, check if it contains Liquid tags (`{{` or `{%`). If it does:

1. Parse with `Solid.parse/1` (strict_filters: true).
2. Store the parsed AST keyed by the config field path (e.g., `["url"]` or `["body", "message"]`).
3. Extract step references from the AST (any access path starting with `steps.`).
4. Validate that every referenced step ID exists in the graph.
5. Validate that the referenced step is topologically upstream of the current step (no forward references that the execution order can't satisfy).

Non-string values (numbers, booleans, lists of non-strings) pass through unchanged.

#### Topology analysis

- **Entry steps**: steps with no inbound connections. At least one must exist.
- **Fan-out regions**: a Splitter step followed by downstream steps, terminated by an Aggregator. These map to Runic FanOut/pipeline/FanIn.
- **Join points**: steps with multiple inbound connections from different branches. These map to Runic Join.
- **Topological order**: a valid execution ordering used to verify that expression references don't create unsatisfiable dependencies.

#### Compiled hash

Computed from the IR after stripping non-semantic fields (positions, notes, viewport). Two published versions with the same compiled hash are runtime-equivalent, even if their editor metadata differs. This supports the audit use case described in workflow-definition-design.md.

### 1.3 Runtime Start (Execution Begins)

Responsibility: build a live Runic `%Workflow{}` from the IR, inject runtime context, start execution.

```elixir
def build_runic_workflow(%CompiledWorkflow{} = ir, runtime_opts) do
  workflow = Workflow.new()

  # 1. Create components from compiled steps
  {workflow, component_map} =
    Enum.reduce(ir.steps, {workflow, %{}}, fn {step_id, compiled_step}, {wf, map} ->
      component = build_component(compiled_step, ir)
      wf = Workflow.add(wf, component, name: step_id)
      {wf, Map.put(map, step_id, component)}
    end)

  # 2. Wire connections as Runic edges
  workflow =
    Enum.reduce(ir.edges, workflow, fn edge, wf ->
      wire_edge(wf, edge, component_map)
    end)

  # 3. Attach scheduler policies
  workflow = attach_policies(workflow, ir, runtime_opts)

  # 4. Store metadata for expression context construction
  workflow =
    Workflow.put_metadata(workflow, :fizz_context, %{
      step_id_to_hash: build_step_hash_index(workflow, component_map),
      runtime_scope: runtime_opts[:scope],
      run_id: runtime_opts[:run_id],
      definition_id: ir.definition_id,
      credential_cache: runtime_opts[:credentials]
    })

  workflow
end
```

The `build_component/2` function dispatches based on step type:

| Step Kind | Runic Component |
|-----------|----------------|
| Regular action/transform | `AuthoredStep` (custom, implements Invokable) |
| Condition | `AuthoredCondition` wrapping `AuthoredStep` → Runic Condition |
| Splitter | Runic `FanOut` wrapping `AuthoredStep` |
| Aggregator | Runic `Reduce` with `FanIn` using executor's init/reducer |
| Join | Runic `Join` with configured mode |
| Wait/Sleep | `AuthoredStep` that produces a timer fact, triggers passivation |

### 1.4 Runtime Execution (Per Step)

Responsibility: Runic's three-phase cycle drives everything. Our code hooks into Phase 1 and Phase 2 via the `AuthoredStep` component.

```
React cycle:
  PREPARE (Phase 1 -- full workflow access)
    For each ready AuthoredStep:
      1. Build expression context from workflow fact graph
      2. Resolve all expressions in config template against context
      3. Determine expression mode per field (value/template/predicate)
      4. Pack resolved config into CausalContext.meta_context
      5. Return %Runnable{} with stable idempotency key

  EXECUTE (Phase 2 -- isolated, parallelizable, distributable)
    For each Runnable:
      1. Read resolved config from meta_context
      2. Read input value from input_fact
      3. Build runtime_ctx (credentials, scope, run metadata)
      4. Call executor_module.execute(resolved_config, input_value, runtime_ctx)
      5. Return result as Fact value

  APPLY (Phase 3 -- sequential, back in workflow context)
    Runic applies result facts to the graph
    New facts become available for the next cycle's expression context
    Checkpoint via Store adapter (SQLite write)
    Plan next cycle
```

---

## 2. The Compiled IR

### 2.1 Structure

```elixir
defmodule Fizz.Workflows.Compiler.CompiledWorkflow do
  @moduledoc """
  The intermediate representation produced at publish time and consumed
  at runtime to build a Runic Workflow. JSON-serializable for storage,
  inspectable for debugging, versioned for migration.
  """

  @type t :: %__MODULE__{
    version: pos_integer(),
    definition_id: String.t(),
    definition_version_id: String.t(),
    steps: %{String.t() => compiled_step()},
    edges: [compiled_edge()],
    entry_step_ids: [String.t()],
    fan_out_regions: [fan_out_region()],
    join_points: [join_point()],
    topological_order: [String.t()],
    expression_index: %{String.t() => [expression_ref()]},
    metadata: map()
  }

  @type compiled_step :: %{
    step_id: String.t(),
    type_id: String.t(),
    executor: String.t(),
    config: map(),
    parsed_expressions: %{list(String.t()) => binary()},
    expression_mode_hints: %{list(String.t()) => :value | :template | :predicate},
    scheduler_policy: map() | nil
  }

  @type compiled_edge :: %{
    source_step_id: String.t(),
    source_output: String.t(),
    target_step_id: String.t(),
    target_input: String.t()
  }

  @type fan_out_region :: %{
    splitter_step_id: String.t(),
    inner_step_ids: [String.t()],
    aggregator_step_id: String.t()
  }

  @type join_point :: %{
    step_id: String.t(),
    source_step_ids: [String.t()],
    mode: String.t()
  }

  @type expression_ref :: %{
    step_id: String.t(),
    field_path: [String.t()],
    referenced_step_ids: [String.t()]
  }

  defstruct [
    :version,
    :definition_id,
    :definition_version_id,
    :steps,
    :edges,
    :entry_step_ids,
    :fan_out_regions,
    :join_points,
    :topological_order,
    :expression_index,
    :metadata
  ]
end
```

### 2.2 Storage

The IR is stored as a dedicated column on `workflow_definition_versions`:

```elixir
field :compiled_ir, :binary
```

Serialized with `:erlang.term_to_binary(ir, [:compressed])` because the parsed Solid ASTs are Elixir terms that don't round-trip through JSON cleanly. The `:compressed` flag keeps storage small.

The `compiled_hash` column (already in the schema) is computed from a canonical JSON serialization of the IR with non-semantic fields stripped. This means `compiled_hash` can be compared across systems without deserializing the binary IR.

### 2.3 IR Versioning

The `version` field on `CompiledWorkflow` is a schema version for the IR format itself (not the workflow definition version). When the compiler changes how it structures the IR, this version increments. The runtime checks `ir.version` and can either:

- Reject incompatible versions (forcing a re-publish)
- Apply a migration function for backwards-compatible changes

For v1, the version is `1` and re-publish is the migration strategy.

### 2.4 Parsed Expression Storage

Each parsed expression is stored as `%{field_path => serialized_ast}` where:

- `field_path` is a list of string keys into the config map (e.g., `["body", "message"]` for `config["body"]["message"]`)
- `serialized_ast` is `:erlang.term_to_binary(solid_ast)` — the output of `Solid.parse/1`

The config map itself retains the original string values (useful for display, debugging, and the expression editor). The parsed ASTs are a parallel index that the runtime uses instead of re-parsing.

### 2.5 Expression Mode Hints

At publish time, the compiler determines each expression field's mode:

- **Value mode**: the field contains exactly one `{{ ... }}` output tag and nothing else. The runtime preserves the native type (map, list, number, boolean).
- **Template mode**: the field contains text mixed with `{{ ... }}` or `{% ... %}` tags. The runtime renders to a string.
- **Predicate mode**: declared by the step type's config schema (e.g., a condition step's `expression` field). The runtime coerces to boolean.

These hints are stored per field path in the IR so the runtime doesn't need to re-analyze expression shapes.

---

## 3. Expression System

### 3.1 Lifecycle

```
Author writes:    "https://api.example.com/{{ steps.fetch_config.value.base_path }}/orders"
                   │
Publish parses:    Solid.parse/1 → AST stored in IR
                   │
Publish validates: "fetch_config" exists and is upstream of this step
                   │
Runtime prepares:  AST evaluated against context → "https://api.example.com/v2/orders"
                   │
Executor receives: resolved string, no Liquid syntax visible
```

### 3.2 Expression Evaluation

```elixir
defmodule Fizz.Workflows.Runtime.ExpressionEvaluator do
  @moduledoc """
  Evaluates Solid expressions against a workflow context map.
  Called during Runic Phase 1 (Prepare) for each step.
  """

  @doc """
  Resolve all expressions in a step's config, returning a fully-resolved config map.
  """
  def resolve_config(config, parsed_expressions, mode_hints, context) do
    Enum.reduce(parsed_expressions, config, fn {field_path, ast_binary}, cfg ->
      ast = :erlang.binary_to_term(ast_binary)
      mode = Map.get(mode_hints, field_path, :template)
      resolved_value = evaluate(ast, context, mode)
      put_in_path(cfg, field_path, resolved_value)
    end)
  end

  @doc """
  Evaluate a single parsed expression against a context.
  """
  def evaluate(ast, context, mode) do
    case mode do
      :value ->
        evaluate_value(ast, context)

      :template ->
        evaluate_template(ast, context)

      :predicate ->
        evaluate_predicate(ast, context)
    end
  end

  # Value mode: if the AST is a single output node, preserve native type.
  defp evaluate_value(ast, context) do
    case extract_single_output(ast) do
      {:ok, variable_path} ->
        resolve_path(context, variable_path)

      :not_single_output ->
        # Falls back to template rendering (stringifies)
        {:ok, rendered} = Solid.render(ast, context)
        IO.iodata_to_binary(rendered)
    end
  end

  # Template mode: always renders to string.
  defp evaluate_template(ast, context) do
    {:ok, rendered} = Solid.render(ast, context)
    IO.iodata_to_binary(rendered)
  end

  # Predicate mode: evaluate and coerce to boolean.
  defp evaluate_predicate(ast, context) do
    result = evaluate_value(ast, context)
    coerce_to_boolean(result)
  end

  # Resolve a dot-path like ["steps", "fetch_orders", "value", "body"]
  # against the context map.
  defp resolve_path(context, path) do
    Enum.reduce_while(path, context, fn
      segment, acc when is_map(acc) ->
        case Map.get(acc, segment) do
          nil -> {:halt, nil}
          value -> {:cont, value}
        end

      _segment, _acc ->
        {:halt, nil}
    end)
  end

  defp coerce_to_boolean(nil), do: false
  defp coerce_to_boolean(false), do: false
  defp coerce_to_boolean(0), do: false
  defp coerce_to_boolean(""), do: false
  defp coerce_to_boolean([]), do: false
  defp coerce_to_boolean(_), do: true

  # Walk into a nested map at the given path and set the value.
  defp put_in_path(map, [key], value), do: Map.put(map, key, value)
  defp put_in_path(map, [key | rest], value) do
    inner = Map.get(map, key, %{})
    Map.put(map, key, put_in_path(inner, rest, value))
  end
end
```

### 3.3 Recursive Config Evaluation

Step configs can contain nested maps and lists with expressions at any depth. The expression discovery phase at publish time walks the entire config tree, so `parsed_expressions` already contains entries for nested fields like `["headers", "Authorization"]`.

For configs that are entirely dynamic (e.g., a JSON body field set to `{{ steps.build_payload.value }}`), the value mode evaluation returns the native Elixir map/list directly, which becomes the resolved config value for that field.

### 3.4 Filter Registration

Custom filters are registered as a single module passed to Solid's render context:

```elixir
defmodule Fizz.Workflows.Runtime.ExpressionFilters do
  @moduledoc """
  Custom Solid filters for the Fizz expression system.
  Registered once at application startup.
  """

  # Predicates
  def eq(value, [target | _]), do: value == target
  def ne(value, [target | _]), do: value != target
  def gt(value, [target | _]), do: value > target
  def gte(value, [target | _]), do: value >= target
  def lt(value, [target | _]), do: value < target
  def lte(value, [target | _]), do: value <= target
  def contains(value, [target | _]) when is_list(value), do: target in value
  def contains(value, [target | _]) when is_binary(value), do: String.contains?(value, target)
  def blank(value, _), do: value in [nil, "", [], %{}]
  def present(value, args), do: !blank(value, args)

  # Data access
  def dig(value, [path | _]) when is_binary(path) do
    path |> String.split(".") |> Enum.reduce(value, &safe_get/2)
  end
  def pluck(value, [key | _]) when is_list(value), do: Enum.map(value, &safe_get(key, &1))
  def keys(value, _) when is_map(value), do: Map.keys(value)
  def values(value, _) when is_map(value), do: Map.values(value)

  # ... remaining filters as defined in expression-design-guide.md

  defp safe_get(key, map) when is_map(map), do: Map.get(map, key)
  defp safe_get(_, _), do: nil
end
```

### 3.5 Expression Safety

- **Timeout**: expression evaluation is bounded by a configurable timeout (default 100ms). Solid templates that loop or recurse excessively are killed.
- **No side effects**: Solid does not allow arbitrary Elixir calls. Custom filters are pure functions.
- **Strict filters**: unknown filter names fail at publish time, not runtime.
- **No includes/partials**: the Solid parser is configured without include support.

### 3.6 The `steps.X.body` Sugar Question

Each step produces a single output value. In the expression context, this value is placed at `steps.{step_id}`. If the value is a map like `%{"body" => ..., "headers" => ..., "status" => 200}`, then `steps.fetch_orders.body` drills into it directly.

No wrapper key like `.value` or `.output` is needed in the context — the step's output value IS the value at `steps.{step_id}`. This means:

- `{{ steps.fetch_orders }}` returns the full output (value mode preserves the map)
- `{{ steps.fetch_orders.body }}` drills into the output map
- `{{ steps.fetch_orders.body.id }}` drills deeper

If we later want to expose metadata alongside the value (e.g., step duration, retry count), we can introduce a wrapper then. For v1, the output value is placed directly, keeping expressions as short as possible.

---

## 4. The AuthoredStep Component

### 4.1 Overview

`AuthoredStep` is a custom Runic component that bridges the Fizz step executor model with Runic's Invokable protocol. It carries the compiled step metadata and implements expression resolution in Phase 1.

### 4.2 Struct Definition

```elixir
defmodule Fizz.Workflows.Runtime.AuthoredStep do
  @moduledoc """
  A Runic workflow component that wraps a Fizz step executor.

  Created at runtime from the CompiledWorkflow IR. Implements
  Runic's Invokable protocol to integrate expression resolution
  into Runic's three-phase execution model.
  """

  @enforce_keys [:step_id, :type_id, :executor_module, :config_template]
  defstruct [
    :step_id,
    :type_id,
    :executor_module,
    :config_template,
    :parsed_expressions,
    :expression_mode_hints,
    :hash,
    :name
  ]
end
```

### 4.3 Component Protocol Implementation

```elixir
defimpl Runic.Workflow.Component, for: Fizz.Workflows.Runtime.AuthoredStep do
  def hash(%{hash: hash}), do: hash
  def source(%{step_id: id}), do: id
  def inputs(_step), do: [:main]
  def outputs(_step), do: [:main]

  def connectable?(_step, _other), do: true

  def connect(step, other, opts) do
    # Default Runic edge wiring
    Runic.Workflow.Component.default_connect(step, other, opts)
  end
end
```

### 4.4 Invokable Protocol Implementation

This is where expression resolution meets Runic's execution model.

```elixir
defimpl Runic.Workflow.Invokable, for: Fizz.Workflows.Runtime.AuthoredStep do
  alias Runic.Workflow
  alias Runic.Workflow.{Runnable, CausalContext, Fact}
  alias Fizz.Workflows.Runtime.{ExpressionEvaluator, ContextBuilder}

  def match_or_execute(_step), do: :execute

  def prepare(%AuthoredStep{} = step, %Fact{} = input_fact, %Workflow{} = workflow) do
    # Phase 1: full workflow access. Build context and resolve expressions.

    # 1. Build the expression context from completed step outputs
    context = ContextBuilder.build(workflow, step.step_id)

    # 2. Resolve all expressions in the config template
    resolved_config =
      ExpressionEvaluator.resolve_config(
        step.config_template,
        step.parsed_expressions,
        step.expression_mode_hints,
        context
      )

    # 3. Build the Runnable with resolved config in meta_context
    runnable = %Runnable{
      id: :erlang.phash2({step.hash, input_fact.hash}),
      node: step,
      input_fact: input_fact,
      context: %CausalContext{
        node_hash: step.hash,
        input_fact: input_fact,
        meta_context: %{
          resolved_config: resolved_config,
          step_id: step.step_id,
          executor_module: step.executor_module
        }
      },
      status: :pending
    }

    {:ok, runnable}
  end

  def execute(%Runnable{} = runnable) do
    # Phase 2: isolated execution. No workflow access.

    meta = runnable.context.meta_context
    config = meta.resolved_config
    input_value = runnable.input_fact.value
    executor = meta.executor_module

    # Build minimal runtime context (credentials, scope, run metadata)
    # These are carried in meta_context, injected at workflow build time
    runtime_ctx = %{
      run_id: meta[:run_id],
      step_id: meta[:step_id],
      scope: meta[:scope],
      credentials: meta[:credentials]
    }

    case executor.execute(config, input_value, runtime_ctx) do
      {:ok, result} ->
        apply_fn = fn workflow ->
          fact = Fact.new(result, ancestry: {runnable.input_fact.hash, nil})
          Workflow.add_fact(workflow, runnable.node, fact)
        end

        %{runnable | status: :completed, result: result, apply_fn: apply_fn}

      {:error, reason} ->
        %{runnable | status: :failed, error: reason}
    end
  end
end
```

### 4.5 How Runtime Context Flows

Runtime-specific values (credentials, scope, run metadata) are injected once at workflow build time into the workflow's metadata. During `prepare`, the `ContextBuilder` reads these from the workflow and includes them in `meta_context` so they're available during isolated Phase 2 execution.

```elixir
# At workflow build time (Section 1.3):
Workflow.put_metadata(workflow, :fizz_runtime, %{
  run_id: run_id,
  scope: scope,
  credentials: resolved_credentials
})

# In ContextBuilder.build/2:
runtime = Workflow.get_metadata(workflow, :fizz_runtime)
# runtime values forwarded into meta_context for Phase 2
```

---

## 5. Workflow Context Model

### 5.1 Context Shape

The expression context is a flat map with well-known top-level keys:

```elixir
%{
  "input" => %{...},          # workflow's initial trigger input
  "steps" => %{               # completed step outputs, keyed by step_id
    "fetch_orders" => %{       # the step's output value (a map in this case)
      "body" => [...],
      "status" => 200,
      "headers" => %{...}
    },
    "filter_active" => [...]   # this step's output was a list
  },
  "workflow" => %{             # workflow execution metadata
    "id" => "run_abc123",
    "definition_id" => "def_xyz",
    "started_at" => "2026-03-12T10:00:00Z"
  },
  "env" => %{                  # environment variables (safe subset)
    "environment" => "production"
  }
}
```

### 5.2 Context Construction

```elixir
defmodule Fizz.Workflows.Runtime.ContextBuilder do
  @moduledoc """
  Builds the expression context map from a Runic workflow's current state.
  Called during Phase 1 (Prepare) for each step that has expressions.
  """

  alias Runic.Workflow

  @doc """
  Build the full expression context for a step about to execute.

  Only includes outputs from steps that have completed (facts exist in the
  workflow). Steps that haven't run yet are absent from `steps`, which
  causes expressions referencing them to resolve to nil.
  """
  def build(%Workflow{} = workflow, _current_step_id) do
    runtime = Workflow.get_metadata(workflow, :fizz_runtime) || %{}
    step_index = Workflow.get_metadata(workflow, :fizz_step_index) || %{}

    %{
      "input" => extract_input(workflow),
      "steps" => build_step_outputs(workflow, step_index),
      "workflow" => build_workflow_metadata(runtime),
      "env" => build_env_context(runtime)
    }
  end

  # Extract the workflow's initial input fact value.
  # This is the first fact fed to the workflow via Workflow.react/2.
  defp extract_input(workflow) do
    case Workflow.facts(workflow) do
      [%{value: input} | _] -> input
      _ -> %{}
    end
  end

  # Walk the step index (step_id -> component hash) and collect
  # output values from completed steps.
  defp build_step_outputs(workflow, step_index) do
    Enum.reduce(step_index, %{}, fn {step_id, component_name}, acc ->
      case Workflow.raw_productions(workflow, component_name) do
        [value | _] -> Map.put(acc, step_id, value)
        [] -> acc
      end
    end)
  end

  defp build_workflow_metadata(runtime) do
    %{
      "id" => runtime[:run_id],
      "definition_id" => runtime[:definition_id],
      "started_at" => runtime[:started_at]
    }
  end

  defp build_env_context(runtime) do
    %{
      "environment" => runtime[:environment] || "development"
    }
  end
end
```

### 5.3 Step Index

The step index maps authored step IDs to Runic component names (used by `Workflow.raw_productions/2`). It is built once at workflow construction time and stored as workflow metadata:

```elixir
# Built during Section 1.3 (Runtime Start)
step_index =
  for {step_id, _compiled_step} <- ir.steps, into: %{} do
    {step_id, step_id}  # component name == step_id (set via Workflow.add/3 name: opt)
  end

Workflow.put_metadata(workflow, :fizz_step_index, step_index)
```

This avoids searching the workflow graph on every context build. The index is stable for the lifetime of the execution.

### 5.4 Context Scoping Rules

| Key | Source | Availability |
|-----|--------|-------------|
| `input` | Initial workflow trigger input | Always, from the first step onward |
| `steps.X` | Output of step X | Only after step X completes. `nil` if not yet run. |
| `workflow.id` | Workflow run metadata | Always |
| `workflow.definition_id` | Published definition metadata | Always |
| `env.environment` | Runtime environment | Always |

Expressions referencing a step that hasn't completed resolve to `nil`. The expression system does not error on missing references — `nil` propagates through dot-access and most filters return `nil` for `nil` input. This matches Liquid's permissive behavior.

### 5.5 Historical State

Runic's fact graph preserves the complete causal history of every production. The expression context (the `steps` map) exposes only the **latest** output of each step. This is the right default for most expressions.

If time-travel or historical access is needed (e.g., "what was the value of step X the second time it ran in a loop?"), this should be exposed through a dedicated filter or a separate context key, not by making the default context carry full history. For v1, this is out of scope.

### 5.6 Context and Checkpointing

The expression context is ephemeral — it is rebuilt from the workflow's fact graph on every prepare call. It is never persisted. This means:

- After a crash and restore from checkpoint, context is rebuilt correctly from the restored workflow.
- No separate context persistence or cache invalidation logic.
- The Runic workflow log remains the single source of truth.

### 5.7 Future Optimization: Dependency-Scoped Context

At publish time, the compiler already extracts which step IDs each expression references (stored in `expression_index`). A future optimization can use this:

```elixir
# Instead of building the full steps map:
defp build_step_outputs(workflow, step_index) do ...all steps... end

# Build only what this step needs:
defp build_scoped_step_outputs(workflow, step_index, referenced_step_ids) do
  Enum.reduce(referenced_step_ids, %{}, fn step_id, acc ->
    component_name = Map.get(step_index, step_id)
    case Workflow.raw_productions(workflow, component_name) do
      [value | _] -> Map.put(acc, step_id, value)
      [] -> acc
    end
  end)
end
```

This reduces context construction from O(all completed steps) to O(referenced steps). The expression_index is already in the IR; the optimization is purely a runtime change.

---

## 6. Special Step Compilation

### 6.1 Splitter -> Runic FanOut

A Splitter step maps to a Runic FanOut that wraps the extraction logic:

```elixir
def compile_splitter(%{step_id: step_id, config: config} = compiled_step, _ir) do
  # The extraction step (reads the field from input)
  extraction_step = build_authored_step(compiled_step)

  # Wrap in FanOut — Runic expands the list output into individual facts
  %Runic.Workflow.FanOut{
    step: extraction_step,
    name: step_id
  }
end
```

### 6.2 Aggregator -> Runic Reduce/FanIn

An Aggregator step maps to a Runic FanIn with init/reducer derived from the configured operation:

```elixir
def compile_aggregator(%{step_id: step_id, config: config}, _ir) do
  operation = Map.get(config, "operation", "collect")

  %Runic.Workflow.FanIn{
    name: step_id,
    init: Fizz.Steps.Executors.Aggregator.init_for_operation(operation),
    reducer: Fizz.Steps.Executors.Aggregator.reducer_for_operation(operation)
  }
end
```

### 6.3 Join -> Runic Join

A Join step maps directly to Runic's Join component:

```elixir
def compile_join(%{step_id: step_id, config: config}, _ir) do
  %Runic.Workflow.Join{
    name: step_id,
    # Runic Join waits for all parent facts before firing
    # The join mode (zip_nil, wait_all, etc.) is applied in the
    # Join executor's work function after facts are collected
  }
end
```

### 6.4 Condition -> Runic Condition

A Condition step compiles to a Runic Condition that wraps the predicate evaluation:

```elixir
def compile_condition(%{step_id: step_id} = compiled_step, ir) do
  authored_step = build_authored_step(compiled_step)

  # The condition evaluates the step's predicate expression
  # and returns true/false, which Runic uses for flow control
  %Runic.Workflow.Condition{
    name: step_id,
    work: fn input ->
      # Expression resolution happens in prepare via AuthoredStep
      # By the time this runs, config is already resolved
      # The condition executor returns {:ok, true/false}
      case authored_step.executor_module.execute(
        input.resolved_config,
        input.value,
        input.runtime_ctx
      ) do
        {:ok, result} -> coerce_to_boolean(result)
        _ -> false
      end
    end
  }
end
```

Note: The exact integration pattern for conditions depends on how Runic's Condition interacts with the Invokable protocol. If Runic Conditions don't support custom prepare logic, we may need to use a Rule (Condition + Reaction pair) instead, or implement a custom `AuthoredCondition` that wraps the Condition behavior with expression resolution. The key invariant is that expression resolution always happens in Phase 1 — the specific Runic component type is an implementation detail.

### 6.5 Edge Wiring

Connections become Runic edges. The source_output/target_input handles map to edge labels:

```elixir
def wire_edge(workflow, edge, component_map) do
  source = Map.fetch!(component_map, edge.source_step_id)
  target = Map.fetch!(component_map, edge.target_step_id)

  # For condition steps, the source_output ("true"/"false") determines
  # which branch the edge belongs to
  label =
    case edge.source_output do
      "main" -> :flow
      "true" -> {:conditional, true}
      "false" -> {:conditional, false}
      other -> {:output, other}
    end

  Workflow.connect(workflow, source, target, label: label)
end
```

---

## 7. Runic Alignment

### 7.1 What We Use As-Is

| Runic Feature | How We Use It |
|---------------|--------------|
| Three-phase execution | Expression resolution in Phase 1, executor in Phase 2, state update in Phase 3 |
| Fact graph with causal ancestry | Step outputs as facts; context reads from productions |
| Content-addressed hashing | Idempotency keys for durable execution |
| `Workflow.log/1` / `from_log/1` | Checkpoint persistence in SQLite |
| FanOut / FanIn / Reduce | Splitter/Aggregator step compilation targets |
| Join | Multi-branch convergence |
| SchedulerPolicy + PolicyDriver | Per-step retry, timeout, backoff, fallback |
| Runner + Worker + Store | Execution lifecycle, checkpointing, crash recovery |
| `CausalContext.meta_context` | Carrying resolved expression values from Phase 1 to Phase 2 |
| `Workflow.put_metadata/3` | Storing step index and runtime context on the workflow |
| `Workflow.raw_productions/2` | Reading step outputs for expression context |
| Telemetry events | Observability integration |

### 7.2 What We Extend Via Protocols

| Extension | Mechanism |
|-----------|-----------|
| `AuthoredStep` component | Implements `Component` + `Invokable` protocols |
| `AuthoredCondition` (if needed) | Implements `Invokable` with condition semantics |
| Custom `Store` adapter | Implements `Runner.Store` behaviour (already planned in durable-workflows-design) |

### 7.3 What Might Need Changes in Runic

These are areas where the design may encounter friction with Runic's current implementation. Each should be validated during implementation.

**`meta_context` capacity.** The design relies on `CausalContext.meta_context` to carry resolved config between phases. If `meta_context` is not populated during prepare for standard Step components, or if it's typed too narrowly, we need either:
- A small Runic change to make `meta_context` a generic map available to all component types
- Or our `AuthoredStep` Invokable implementation sets it directly (likely works since we control the Runnable construction)

**`Workflow.put_metadata/3` availability.** The design stores the step index and runtime context on the workflow struct. If Runic doesn't expose a generic metadata store on `%Workflow{}`, we need either:
- A Runic addition (a `metadata` field on the struct)
- Or we store this in the graph's vertex properties

**`raw_productions/2` by component name.** The context builder calls `Workflow.raw_productions(workflow, component_name)`. This should work since we register components with names matching step IDs. Verify that `raw_productions/2` accepts a name (not just a hash).

**Condition branch edges.** The design wires condition outputs ("true"/"false") as labeled edges. Verify that Runic's graph traversal respects edge labels for conditional flow control, and that only the matching branch's downstream steps become runnable after a condition evaluates.

### 7.4 Things We Deliberately Do NOT Do

- **We do not build a parallel event store.** Runic's log IS the event store.
- **We do not implement custom replay.** `Workflow.from_log/1` handles reconstruction.
- **We do not manage worker lifecycle.** `Runic.Runner.Worker` handles dispatch loops, checkpointing, and crash recovery.
- **We do not build a second fact tracking system.** The workflow's fact graph is the source of truth for step outputs.
- **We do not modify Runic's execution loop.** We plug into it via protocols.

---

## 8. The Compiler Module

### 8.1 Entry Point

```elixir
defmodule Fizz.Workflows.Compiler do
  @moduledoc """
  Compiles an authored workflow definition version into a CompiledWorkflow IR,
  and builds Runic Workflows from compiled IRs at runtime.
  """

  alias Fizz.Workflows.Compiler.{
    CompiledWorkflow,
    ExpressionDiscovery,
    TopologyAnalyzer,
    StepCompiler
  }
  alias Fizz.Workflows.DefinitionVersion

  @doc """
  Compile a published definition version into an IR.
  Returns {:ok, %CompiledWorkflow{}} or {:error, errors}.
  Called at publish time.
  """
  def compile(%DefinitionVersion{} = version) do
    with {:ok, parsed_steps} <- discover_expressions(version.steps),
         {:ok, topology} <- analyze_topology(version.steps, version.connections),
         :ok <- validate_expression_refs(parsed_steps, topology),
         {:ok, compiled_steps} <- compile_steps(parsed_steps, version),
         {:ok, ir} <- build_ir(compiled_steps, topology, version) do
      {:ok, ir}
    end
  end

  @doc """
  Build a Runic Workflow from a compiled IR.
  Called at runtime when starting a new execution.
  """
  def to_runic(%CompiledWorkflow{} = ir, runtime_opts) do
    build_runic_workflow(ir, runtime_opts)
  end

  @doc """
  Compute a deterministic hash of the compiled IR for comparison.
  """
  def hash(%CompiledWorkflow{} = ir) do
    ir
    |> canonical_form()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
```

### 8.2 Expression Discovery

```elixir
defmodule Fizz.Workflows.Compiler.ExpressionDiscovery do
  @moduledoc """
  Walks step configs to find, parse, and catalog Liquid expressions.
  """

  @liquid_pattern ~r/\{\{.*?\}\}|\{%.*?%\}/s

  @doc """
  Walk a step's config and return parsed expressions with their field paths.
  """
  def discover(config) do
    discover_recursive(config, [])
  end

  defp discover_recursive(value, path) when is_binary(value) do
    if Regex.match?(@liquid_pattern, value) do
      case Solid.parse(value, strict_filters: true) do
        {:ok, ast} ->
          mode = detect_mode(ast, value)
          refs = extract_step_references(ast)
          [{Enum.reverse(path), ast, mode, refs}]

        {:error, reason} ->
          raise Fizz.Workflows.CompileError,
            message: "Invalid expression at #{inspect(path)}: #{inspect(reason)}"
      end
    else
      []
    end
  end

  defp discover_recursive(value, path) when is_map(value) do
    Enum.flat_map(value, fn {k, v} ->
      discover_recursive(v, [k | path])
    end)
  end

  defp discover_recursive(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {v, i} ->
      discover_recursive(v, [Integer.to_string(i) | path])
    end)
  end

  defp discover_recursive(_value, _path), do: []

  # A single {{ ... }} with no surrounding text -> value mode
  # Mixed content -> template mode
  defp detect_mode(ast, original_string) do
    trimmed = String.trim(original_string)

    if Regex.match?(~r/^\{\{.*\}\}$/s, trimmed) and
       not Regex.match?(~r/\{%/, trimmed) do
      :value
    else
      :template
    end
  end

  # Extract step IDs referenced in the AST.
  # Looks for access paths starting with "steps".
  defp extract_step_references(ast) do
    ast
    |> collect_variable_paths()
    |> Enum.filter(fn path -> List.first(path) == "steps" end)
    |> Enum.map(fn [_steps, step_id | _rest] -> step_id end)
    |> Enum.uniq()
  end
end
```

---

## 9. Execution Walkthrough

A concrete example showing how data flows through the system.

### 9.1 Authored Workflow

```json
{
  "steps": [
    {
      "id": "fetch_orders",
      "type_id": "http_request",
      "config": {
        "url": "https://api.example.com/orders",
        "method": "GET",
        "headers": {
          "Authorization": "Bearer {{ steps.get_token.access_token }}"
        }
      }
    },
    {
      "id": "get_token",
      "type_id": "http_request",
      "config": {
        "url": "https://auth.example.com/token",
        "method": "POST",
        "body": "{{ input.auth_payload }}"
      }
    },
    {
      "id": "notify",
      "type_id": "notify",
      "config": {
        "channel": "email",
        "message": "Found {{ steps.fetch_orders.body | size }} orders"
      }
    }
  ],
  "connections": [
    {"source_step_id": "get_token", "target_step_id": "fetch_orders"},
    {"source_step_id": "fetch_orders", "target_step_id": "notify"}
  ]
}
```

### 9.2 Publish-Time Compilation

Topology: `get_token` -> `fetch_orders` -> `notify`

Expressions discovered:

| Step | Field Path | AST | Mode | Refs |
|------|-----------|-----|------|------|
| get_token | `["body"]` | `Solid(input.auth_payload)` | value | [] |
| fetch_orders | `["headers", "Authorization"]` | `Solid(Bearer + steps.get_token.access_token)` | template | ["get_token"] |
| notify | `["message"]` | `Solid(Found + steps.fetch_orders.body\|size + orders)` | template | ["fetch_orders"] |

Reference validation passes: `get_token` is upstream of `fetch_orders`, and `fetch_orders` is upstream of `notify`.

### 9.3 Runtime Execution

**Cycle 1: get_token**

1. PREPARE: Context is `%{"input" => %{"auth_payload" => %{...}}, "steps" => %{}}`. Expression `{{ input.auth_payload }}` resolves in value mode to the map. Resolved config: `%{"body" => %{"grant_type" => "client_credentials", ...}}`.
2. EXECUTE: HttpRequest executor makes the POST call. Returns `%{"access_token" => "abc123", "expires_in" => 3600}`.
3. APPLY: Fact with value `%{"access_token" => "abc123", ...}` enters the graph under `get_token`. Checkpoint.

**Cycle 2: fetch_orders**

1. PREPARE: Context is `%{"input" => ..., "steps" => %{"get_token" => %{"access_token" => "abc123", ...}}}`. Expression `Bearer {{ steps.get_token.access_token }}` resolves in template mode to `"Bearer abc123"`. Resolved config: `%{"headers" => %{"Authorization" => "Bearer abc123"}, ...}`.
2. EXECUTE: HttpRequest executor makes the GET call. Returns `%{"body" => [order1, order2, ...], "status" => 200}`.
3. APPLY: Fact enters graph under `fetch_orders`. Checkpoint.

**Cycle 3: notify**

1. PREPARE: Context has both step outputs. Expression `Found {{ steps.fetch_orders.body | size }} orders` resolves to `"Found 42 orders"`.
2. EXECUTE: Notify executor sends the email.
3. APPLY: Fact enters graph. Workflow satisfies. Final checkpoint.

---

## 10. Error Handling

### 10.1 Compile-Time Errors

Errors from the publish-time compiler are structured and user-facing:

```elixir
defmodule Fizz.Workflows.CompileError do
  defexception [:step_id, :field_path, :message, :category]

  # Categories:
  # :expression_syntax   - Solid.parse/1 failed
  # :expression_ref      - referenced step doesn't exist
  # :forward_ref         - referenced step is not upstream
  # :unknown_filter      - strict_filters rejection
  # :config_validation   - config schema validation failure
  # :topology            - no entry step, cycle detected, etc.
end
```

The compiler collects all errors (does not fail on the first one) so the user sees the complete list of problems to fix.

### 10.2 Runtime Expression Errors

During prepare, if an expression fails to evaluate (e.g., a filter receives an unexpected type), the step's Runnable is marked as failed with a descriptive error. It does not crash the workflow. The SchedulerPolicy determines whether to retry, skip, or halt.

Nil propagation is the default for missing references — `{{ steps.unfinished_step.body }}` evaluates to `nil` (or empty string in template mode), not an error. This matches Liquid's behavior and prevents cascading failures.

### 10.3 Executor Errors

Executor errors (`{:error, reason}`) flow through Runic's normal error handling path: the Runnable is marked failed, PolicyDriver applies retry/fallback policies, and the error is recorded in the workflow log for debugging.

---

## 11. Open Questions

### 11.1 Condition Branch Mechanics

The exact Runic component pattern for condition steps with true/false branches needs implementation validation. Options:

- **Runic Rule**: a Condition + Reaction pair, where the Condition evaluates the predicate and the Reaction gates downstream flow. This is the most natural Runic primitive for conditional logic.
- **Custom Invokable**: `AuthoredCondition` that implements prepare/execute with boolean result semantics.

Recommend prototyping both during implementation to see which integrates more cleanly with Runic's edge traversal.

### 11.2 Solid AST Stability

The design stores parsed Solid ASTs in the IR. If the Solid library updates and changes its internal AST representation, old IRs break. Mitigations:

- Pin the Solid version in mix.lock (standard practice).
- The IR version field allows forcing re-publish on Solid upgrades.
- Alternatively, store a custom intermediate expression AST that we control, and lower to Solid at runtime. This adds complexity for v1 — defer unless AST instability becomes a real problem.

### 11.3 Workflow Metadata on Runic

The design assumes `Workflow.put_metadata/3` and `Workflow.get_metadata/2` exist or can be added to Runic. If not, alternatives:

- Store metadata in a well-known component added to the graph (a "metadata node" that never executes).
- Store metadata in the workflow's graph vertex properties.
- Add a generic `metadata :: map()` field to the `%Workflow{}` struct (small Runic PR).

The last option is cleanest. Raising this as a Runic enhancement request is recommended.

### 11.4 Fan-Out Region Detection

The compiler must detect Splitter -> ... -> Aggregator regions to compile them into Runic FanOut/FanIn structures. The detection algorithm:

1. Find all Splitter steps.
2. For each Splitter, BFS forward through connections.
3. The first Aggregator encountered on all paths is the region's FanIn.
4. All steps between Splitter and Aggregator are the inner pipeline.

Edge cases: nested fan-out regions, Splitters without Aggregators (invalid — catch at validation), multiple Aggregators on different branches (invalid for v1).

This is a graph algorithm question with a well-defined answer, but it needs careful implementation and test coverage.

### 11.5 Loop / Iteration Steps

The current design handles linear DAGs and fan-out/fan-in patterns. Loop constructs (e.g., "retry until condition", "for each page of API results") are not addressed. These would likely compile to Runic Accumulators or StateMachines. Defer to a future design iteration — the IR version field supports adding new compilation targets without breaking existing workflows.

---

## Appendix A: Module Map

```
Fizz.Workflows.Compiler
  .CompiledWorkflow        # IR struct definition
  .ExpressionDiscovery     # walks configs, parses Solid ASTs
  .TopologyAnalyzer        # entry steps, fan-out regions, join points, topo sort
  .StepCompiler            # per-step-type compilation to IR entries
  .ReferenceValidator      # expression refs exist and are upstream

Fizz.Workflows.Runtime
  .AuthoredStep            # custom Runic component (struct + Invokable impl)
  .AuthoredCondition       # custom Runic component for condition steps
  .ContextBuilder          # builds expression context from workflow fact graph
  .ExpressionEvaluator     # evaluates Solid ASTs against context
  .ExpressionFilters       # custom Solid filter module
  .WorkflowBuilder         # IR -> Runic Workflow construction

Fizz.Workflows.Runtime.ExpressionEvaluator
  .resolve_config/4        # resolves all expressions in a step config
  .evaluate/3              # evaluates a single expression with mode

Fizz.Workflows.Runtime.ContextBuilder
  .build/2                 # builds full context from workflow state
```

## Appendix B: Data Flow Summary

```
                    AUTHOR TIME              PUBLISH TIME
                    -----------              ------------
                    Steps (Ecto)  ────────>  ExpressionDiscovery
                    Connections               TopologyAnalyzer
                    StepGroups                StepCompiler
                         │                        │
                         │                   CompiledWorkflow IR
                         │                   (stored on version row)
                         │                        │
                    ─────┼────────────────────────┼──────────────────
                         │                        │
                    RUNTIME START            RUNTIME EXECUTION
                    -------------            -----------------
                         │                        │
                    WorkflowBuilder          Per react cycle:
                    (IR -> Runic)              Prepare:
                         │                      ContextBuilder.build/2
                    %Runic.Workflow{}            ExpressionEvaluator.resolve_config/4
                    + AuthoredSteps              -> meta_context
                    + Policies                 Execute:
                    + Metadata                  executor.execute(resolved, input, ctx)
                         │                     Apply:
                    Runner.start_workflow        Runic applies facts
                    Runner.run(input)            Store checkpoints
```
