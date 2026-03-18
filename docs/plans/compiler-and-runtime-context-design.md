# Workflow Compiler & Runtime Context Design

This document describes how authored workflow definitions are compiled into executable Runic representations, how step configs resolve expressions at runtime, and how runtime context integrates with Runic's model without introducing a mutable state bag.

---

## Design Goals

- The compiler is a pure function: `%DefinitionVersion{}` in, `%Runic.Workflow{}` out.
- Expressions are parsed and validated at publish time, not re-parsed on every execution.
- Step outputs are captured in Runic Accumulators so downstream expressions resolve via `state_of()` — fully native to the graph model.
- Runtime context is a thin query layer over workflow state, not a standalone persisted object.
- `step_groups` are stripped in Phase 1 and never enter the IR or execution graph.
- The `compiled_hash` covers only execution-relevant content so UI-only edits don't produce new hashes.

---

## Compiler Phases

```
Authored Document          Compiler Pipeline              Runic Execution
─────────────────    ──────────────────────────────    ──────────────────

%DefinitionVersion{  Phase 1: Parse & Normalize
  steps,             ──────────────────────────────►  %IR.Graph{}
  connections,           - strip UI-only fields
  step_groups,           - resolve step types from registry
  viewport,              - normalize connection handles
  settings               - topological sort
}
                     Phase 2: Expression Compilation
                     ──────────────────────────────►  %IR.Graph{} (enriched)
                         - parse Liquid expressions via Solid
                         - build access plans per config field
                         - detect context dependencies
                         - validate step references

                     Phase 3: Runic Assembly
                     ──────────────────────────────►  %Runic.Workflow{}
                         - instantiate Runic components
                         - wire connections via Workflow.add/3
                         - create output-capture accumulators
                         - attach run_context requirements
                         - attach scheduler policies

                     Phase 4: Seal & Hash
                     ──────────────────────────────►  {%Workflow{}, compiled_hash}
                         - compute SHA-256 of normalized execution payload
                         - stamp compiler_version
```

---

## Phase 1: Parse & Normalize

Strips the authored document down to execution-relevant content and produces a lightweight IR.

```elixir
defmodule Fizz.Workflows.Compiler do
  alias Fizz.Workflows.Compiler.{Normalizer, ExpressionCompiler, Assembler}

  def compile(%DefinitionVersion{} = version, opts \\ []) do
    with {:ok, ir} <- Normalizer.normalize(version),
         {:ok, ir} <- ExpressionCompiler.compile_expressions(ir),
         {:ok, workflow} <- Assembler.assemble(ir, opts),
         {:ok, hash} <- compute_hash(ir) do
      {:ok, workflow, hash}
    end
  end
end
```

```elixir
defmodule Fizz.Workflows.Compiler.Normalizer do
  def normalize(%DefinitionVersion{} = version) do
    with {:ok, steps} <- normalize_steps(version.steps),
         {:ok, connections} <- normalize_connections(version.connections, steps),
         {:ok, topo_order} <- topological_sort(steps, connections) do
      {:ok, %IR.Graph{
        steps: steps,
        connections: connections,
        topo_order: topo_order,
        entry_step_ids: find_entry_steps(steps, connections)
      }}
    end
  end

  defp normalize_steps(steps) do
    steps
    |> Enum.map(fn step ->
      type = Fizz.Steps.Registry.get(step.type_id)

      %IR.Step{
        id: step.id,
        type_id: step.type_id,
        name: step.name,
        kind: type.step_kind,
        role: type.role,
        config: step.config,
        config_schema: type.config_schema,
        executor: type.executor,
        subnode_slots: type.subnode_slots
      }
    end)
    |> Map.new(&{&1.id, &1})
    |> then(&{:ok, &1})
  end

  defp normalize_connections(connections, steps) do
    connections
    |> Enum.map(fn conn ->
      %IR.Connection{
        id: conn.id,
        source_step_id: conn.source_step_id,
        source_output: conn.source_output || "main",
        target_step_id: conn.target_step_id,
        target_input: conn.target_input || "main"
      }
    end)
    |> then(&{:ok, &1})
  end
end
```

**What gets stripped**: `position`, `notes`, `step_groups`, `viewport`, `settings`, `color`, `font_size`, `collapsed`. These are editor metadata only.

**What gets preserved**: `id`, `type_id`, `name`, `config`, connection topology, handle names.

---

## Phase 2: Expression Compilation

Liquid expressions in step configs become **access plans** — pre-parsed instructions that resolve efficiently at runtime without re-parsing templates on every execution.

### Access Plans

An access plan is a pre-compiled instruction for resolving a config field value at runtime. Expressions are parsed once at publish time, executed many times at runtime.

```elixir
defmodule Fizz.Workflows.Compiler.IR.AccessPlan do
  # A literal value — no resolution needed
  defmodule Literal do
    defstruct [:value]
  end

  # A single {{ expression }} that preserves native type
  defmodule ValueExpression do
    defstruct [
      :source,            # original Liquid string
      :parsed_template,   # pre-parsed Solid AST
      :root_namespace,    # :input | :steps | :workflow | :env
      :access_path,       # ["fetch_orders", "body", "status"]
      :filter_chain,      # [{:to_float, []}, {:round_to, [2]}]
      :step_dependency    # step_id this references (if :steps namespace)
    ]
  end

  # A template string with interpolation — always resolves to string
  defmodule TemplateExpression do
    defstruct [
      :source,
      :parsed_template,
      :step_dependencies  # set of step_ids referenced
    ]
  end

  # A credential reference — resolved at runtime via provider
  defmodule CredentialFetch do
    defstruct [:ref, :field_path]
  end

  # A predicate expression — resolves to boolean
  defmodule PredicateExpression do
    defstruct [
      :source,
      :parsed_template,
      :step_dependencies
    ]
  end
end
```

### Expression Compilation

```elixir
defmodule Fizz.Workflows.Compiler.ExpressionCompiler do
  def compile_expressions(%IR.Graph{} = ir) do
    steps =
      Map.new(ir.steps, fn {id, step} ->
        {id, compile_step_config(step, ir)}
      end)

    {:ok, %{ir | steps: steps}}
  end

  defp compile_step_config(%IR.Step{} = step, ir) do
    {compiled_config, access_plans} =
      walk_config(step.config, step.config_schema, fn field_path, value, _schema_hint ->
        case classify_field(value) do
          :literal ->
            {value, nil}

          :expression ->
            plan = compile_expression(value, step.id, field_path, ir)
            {plan, plan}

          :credential_ref ->
            plan = %IR.AccessPlan.CredentialFetch{ref: value, field_path: field_path}
            {plan, plan}
        end
      end)

    context_deps = extract_context_dependencies(access_plans)

    %{step |
      compiled_config: compiled_config,
      access_plans: Enum.reject(access_plans, &is_nil/1),
      context_deps: context_deps
    }
  end

  defp compile_expression(template_string, _current_step_id, _field_path, _ir) do
    {:ok, parsed} = Solid.parse(template_string)

    case detect_expression_mode(parsed) do
      :value ->
        {root, path, filters} = extract_access_path(parsed)
        step_dep = if root == :steps, do: Enum.at(path, 0)

        %IR.AccessPlan.ValueExpression{
          source: template_string,
          parsed_template: parsed,
          root_namespace: root,
          access_path: path,
          filter_chain: filters,
          step_dependency: step_dep
        }

      :template ->
        deps = extract_step_references(parsed)

        %IR.AccessPlan.TemplateExpression{
          source: template_string,
          parsed_template: parsed,
          step_dependencies: deps
        }

      :predicate ->
        deps = extract_step_references(parsed)

        %IR.AccessPlan.PredicateExpression{
          source: template_string,
          parsed_template: parsed,
          step_dependencies: deps
        }
    end
  end
end
```

### Expression Mode Detection

Follows the rules from the expression design spec:

- **Value expression**: exactly one output tag, nothing else — preserve native type.
- **Template expression**: mixed text plus `{{ }}` and optional `{% %}` — always renders to string.
- **Predicate expression**: single output tag with a comparison filter (`eq`, `gt`, `blank`, etc.) — resolves to boolean.

---

## Phase 3: Runic Assembly

Translates the enriched IR into a live `%Runic.Workflow{}`.

The core decision: **each authored step becomes a Runic Step whose work function is a config-resolution + executor dispatch closure.** The closure captures the compiled config and access plans. At runtime it resolves expressions against the workflow's produced state via Runic's `state_of()` and `context()` mechanisms.

### Assembly Entrypoint

```elixir
defmodule Fizz.Workflows.Compiler.Assembler do
  def assemble(%IR.Graph{} = ir, opts) do
    workflow = Runic.Workflow.new(name: opts[:name] || :compiled_workflow)

    # 1. Build Runic components for each step in topological order.
    #    Steps whose output is referenced downstream get a companion accumulator.
    components =
      Map.new(ir.steps, fn {id, ir_step} ->
        {id, build_component_pair(ir_step, ir)}
      end)

    # 2. Wire into workflow in topological order
    workflow =
      Enum.reduce(ir.topo_order, workflow, fn step_id, wf ->
        ir_step = ir.steps[step_id]
        {work_step, output_acc} = components[step_id]
        parents = upstream_step_ids(step_id, ir.connections)

        wf = add_with_parents(wf, work_step, parents)
        wf = if output_acc, do: Runic.Workflow.add(wf, output_acc, to: work_step.name), else: wf
        wf
      end)

    # 3. Declare run_context requirements
    workflow = attach_context_requirements(workflow, ir)

    {:ok, workflow}
  end

  defp add_with_parents(wf, component, []),
    do: Runic.Workflow.add(wf, component)

  defp add_with_parents(wf, component, [single]),
    do: Runic.Workflow.add(wf, component, to: String.to_atom(single))

  defp add_with_parents(wf, component, parents) do
    # Multiple parents create an implicit Runic Join
    parent_atoms = Enum.map(parents, &String.to_atom/1)
    Runic.Workflow.add(wf, component, to: parent_atoms)
  end
end
```

### Building Step Components

```elixir
defp build_component_pair(%IR.Step{} = ir_step, ir) do
  work_step = build_work_step(ir_step, ir)

  # Only create an output-capture accumulator if any downstream step
  # references this step's output in its expressions
  output_acc =
    if referenced_by_downstream?(ir_step.id, ir) do
      Runic.accumulator(
        nil,
        fn output, _prev -> output end,
        name: :"#{ir_step.id}__output"
      )
    end

  {work_step, output_acc}
end

defp build_work_step(%IR.Step{kind: kind} = ir_step, ir)
     when kind in [:action, :transform, :trigger] do
  compiled_config = ir_step.compiled_config
  executor_mod = ir_step.executor

  # The step's work function receives:
  #   input    — the upstream fact value
  #   meta_ctx — merged meta_context (state_of accumulators) + run_context (platform values)
  Runic.step(
    fn input, meta_ctx ->
      resolution_ctx = build_resolution_context(input, meta_ctx, ir_step)
      config = Fizz.Workflows.Runtime.ConfigResolver.resolve(compiled_config, resolution_ctx, meta_ctx)

      case executor_mod.execute(config, input, meta_ctx) do
        {:ok, output} -> output
        {:error, reason} -> raise Fizz.Workflows.StepError, reason: reason
        {:skip, reason} -> throw({:fizz_skip, reason})
      end
    end,
    name: String.to_atom(ir_step.id)
  )
end

defp build_work_step(%IR.Step{kind: :control_flow} = ir_step, _ir) do
  case ir_step.type_id do
    "condition" -> build_condition_rule(ir_step)
    "switch"    -> build_switch_rules(ir_step)
    "join"      -> build_join_step(ir_step)
  end
end
```

### Control Flow Mapping

Authored control flow steps map onto Runic primitives:

| Authored Step Type | Runic Primitive | Notes |
|-|-|-|
| `condition` | `Runic.rule/1` with guard clause | True branch continues, false branch is a second rule with negated guard |
| `switch` | Multiple `Runic.rule/1` nodes, one per case | Each case is a separate rule with its match predicate |
| `join` | Implicit `Runic.Workflow.Join` | Created automatically by `Workflow.add(component, to: [a, b])` |
| `splitter` (fan-out) | `Runic.map/2` | Maps over collection, creating parallel branches |
| `aggregator` (fan-in) | `Runic.reduce/3` with `map:` option | Collects fan-out results |

### Condition Example

```elixir
defp build_condition_rule(%IR.Step{} = ir_step) do
  compiled_config = ir_step.compiled_config
  executor_mod = ir_step.executor

  # A condition step becomes a Runic rule:
  # the condition function evaluates the predicate,
  # the reaction function passes the input through
  Runic.rule(
    name: String.to_atom(ir_step.id),
    condition: fn input, meta_ctx ->
      resolution_ctx = build_resolution_context(input, meta_ctx, ir_step)
      config = Fizz.Workflows.Runtime.ConfigResolver.resolve(compiled_config, resolution_ctx, meta_ctx)

      case executor_mod.execute(config, input, meta_ctx) do
        {:ok, true} -> true
        {:ok, false} -> false
        _ -> false
      end
    end,
    reaction: fn input -> input end
  )
end
```

---

## Phase 4: Seal & Hash

The compiled hash covers **only execution-relevant content** so two definition versions that produce identical runtime behavior share the same hash even if their UI metadata differs.

```elixir
defp compute_hash(%IR.Graph{} = ir) do
  hashable = %{
    steps:
      ir.steps
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {id, step} ->
        %{id: id, type_id: step.type_id, config: step.config}
      end),
    connections:
      ir.connections
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn conn ->
        %{
          source_step_id: conn.source_step_id,
          source_output: conn.source_output,
          target_step_id: conn.target_step_id,
          target_input: conn.target_input
        }
      end)
    # step_groups excluded
    # viewport excluded
    # settings excluded
    # step names excluded — note that renaming a step changes its id
    # (derived from display name), which changes connection references
    # and therefore the hash. Names are execution-relevant via id generation.
  }

  hash =
    :crypto.hash(:sha256, :erlang.term_to_binary(hashable))
    |> Base.encode16(case: :lower)

  {:ok, hash}
end
```

**Runtime-equivalent comparison**: two versions share the same `compiled_hash` iff they have identical step types, configs, and connection topology.

---

## Step Context & Config Resolution

### The Resolution Context

At runtime, a step's config expressions need to resolve references like `{{ steps.fetch_orders.body }}` or `{{ input.customer.email }}`. Rather than building a giant mutable context map, the resolution layer is a **thin query function over workflow-produced state**.

```elixir
defmodule Fizz.Workflows.Runtime.ConfigResolver do
  @moduledoc """
  Resolves compiled config access plans against runtime state.

  This is NOT a standalone persisted object. It's a query layer
  that reads from:
  - The current step's input fact (the `input` namespace)
  - Prior step outputs indexed by step name (the `steps` namespace)
  - Platform-provided values in run_context (credentials, env, workflow metadata)
  """

  alias Fizz.Workflows.Compiler.IR.AccessPlan

  def resolve(compiled_config, resolution_ctx, meta_ctx) when is_map(compiled_config) do
    Map.new(compiled_config, fn {key, value} ->
      {key, resolve_value(value, resolution_ctx, meta_ctx)}
    end)
  end

  # --- Dispatch by access plan type ---

  defp resolve_value(%AccessPlan.Literal{value: v}, _ctx, _meta), do: v

  defp resolve_value(%AccessPlan.ValueExpression{} = plan, ctx, meta) do
    case plan do
      # Fast path: simple dot-access with no filters skips Solid entirely
      %{filter_chain: [], root_namespace: ns, access_path: path} ->
        get_in_namespace(ctx, ns, path)

      _ ->
        # Full Solid render with type preservation
        bindings = build_solid_bindings(ctx, meta)
        render_value_expression(plan.parsed_template, bindings)
    end
  end

  defp resolve_value(%AccessPlan.TemplateExpression{} = plan, ctx, meta) do
    bindings = build_solid_bindings(ctx, meta)
    {:ok, rendered} = Solid.render(plan.parsed_template, bindings)
    IO.iodata_to_binary(rendered)
  end

  defp resolve_value(%AccessPlan.PredicateExpression{} = plan, ctx, meta) do
    bindings = build_solid_bindings(ctx, meta)
    result = render_value_expression(plan.parsed_template, bindings)
    !!result
  end

  defp resolve_value(%AccessPlan.CredentialFetch{ref: ref}, _ctx, meta) do
    meta[:_credential_resolver].(ref)
  end

  # Recursive walk for nested config maps/lists
  defp resolve_value(map, ctx, meta) when is_map(map), do: resolve(map, ctx, meta)
  defp resolve_value(list, ctx, meta) when is_list(list), do: Enum.map(list, &resolve_value(&1, ctx, meta))
  defp resolve_value(literal, _ctx, _meta), do: literal

  # --- Namespace resolution (fast path, no Solid) ---

  defp get_in_namespace(ctx, :input, path) do
    get_in(ctx.input, Enum.map(path, &Access.key(&1, nil)))
  end

  defp get_in_namespace(ctx, :steps, [step_id | rest]) do
    case Map.get(ctx.step_outputs, step_id) do
      nil -> nil
      output -> get_in(output, Enum.map(rest, &Access.key(&1, nil)))
    end
  end

  defp get_in_namespace(ctx, :workflow, path) do
    get_in(ctx.workflow, Enum.map(path, &Access.key(&1, nil)))
  end

  defp get_in_namespace(ctx, :env, [key | _]) do
    Map.get(ctx.env, key)
  end

  # --- Solid bindings ---

  defp build_solid_bindings(ctx, meta) do
    %{
      "input" => ctx.input,
      "steps" => ctx.step_outputs,
      "workflow" => meta[:workflow] || %{},
      "env" => meta[:env] || %{}
    }
  end
end
```

### The Fast Path

Most expressions in practice are simple references like `{{ steps.fetch_orders.body.id }}` or `{{ input.email }}`. The access plan detects these at compile time and **bypasses Solid entirely at runtime**, using direct `get_in` access. Solid is only invoked for template strings with mixed content or filter chains.

This matters for durable execution: a workflow that sleeps for months and wakes up should resolve config expressions as fast as possible on the hot path.

---

## Runtime Context Strategy

The central question: how do step config expressions reference prior step outputs without a giant mutable context bag?

### The Answer: Output-Capture Accumulators + `state_of()`

Runic already has the mechanism: **`state_of(:component)`** reads the current state of an Accumulator. The compiler creates a companion Accumulator for each step whose output is referenced downstream. The downstream step's work function uses `state_of()` to access it via `meta_ctx`.

This keeps us aligned with Runic's model:

1. **No mutable context bag.** Step outputs are captured in Accumulators, which are proper Runic components with content-addressed state.
2. **Serializable.** Accumulator state is part of `Workflow.log/1` — it survives checkpoint/restore automatically.
3. **Lazy.** The meta_ref system only resolves the specific accumulators that a step actually references, not all upstream outputs.
4. **Causal.** Runic's graph ensures a step only executes after its dependencies (including the accumulators it references via `state_of`) have produced values.

### How It Works

At compile time, the compiler detects which upstream steps each step references in its expressions. During assembly, it creates an Accumulator per referenced step and wires downstream steps to read from them.

```
Authored:
  [Fetch Orders] ──► [Check Status] ──► [Notify Team]
                                         config.message: "Order {{ steps.fetch_orders.body.id }} is {{ steps.check_status.result }}"

Compiled Runic graph:
  fetch_orders ──► fetch_orders__output (accumulator, captures output)
       │                    │
       ▼                    │  (state_of :fetch_orders__output)
  check_status ──► check_status__output (accumulator, captures output)
       │                    │
       ▼                    │  (state_of :check_status__output)
  notify_team ◄─────────────┘
```

The `notify_team` step's work function receives `meta_ctx` containing:

```elixir
%{
  fetch_orders__output_state: %{"body" => %{"id" => 123, ...}},
  check_status__output_state: %{"result" => "paid"},
  # ... platform values from run_context ...
}
```

The `build_resolution_context` function maps this into the namespace structure that `ConfigResolver` expects:

```elixir
defp build_resolution_context(input, meta_ctx, ir_step) do
  # Build the step_outputs map from meta_ctx accumulator states
  step_outputs =
    ir_step.context_deps
    |> Enum.filter(fn dep -> dep.namespace == :steps end)
    |> Map.new(fn dep ->
      acc_key = :"#{dep.step_id}__output_state"
      {dep.step_id, Map.get(meta_ctx, acc_key)}
    end)

  %{
    input: input,
    step_outputs: step_outputs,
    workflow: Map.get(meta_ctx, :workflow, %{}),
    env: Map.get(meta_ctx, :env, %{})
  }
end
```

### Platform Values via `run_context`

Platform-provided values (workflow metadata, environment, credential resolver) are set once at workflow start via `Workflow.put_run_context/2` and flow into every step's `meta_ctx` automatically through Runic's existing `run_context` → `CausalContext` pipeline.

```elixir
defmodule Fizz.Workflows.Runtime.ContextBuilder do
  def build_run_context(scope, workflow_run) do
    %{
      workflow: %{
        id: workflow_run.run_id,
        definition_id: workflow_run.workflow_definition_id,
        version: workflow_run.definition_version
      },
      env: build_env_context(scope),
      _credential_resolver: build_credential_resolver(scope),
      _scope: scope
    }
  end

  defp build_credential_resolver(scope) do
    fn credential_ref ->
      provider_id = "#{credential_ref["provider"]}_#{credential_ref["auth_type"]}"
      provider = Fizz.Integrations.ProviderCatalog.get(provider_id)
      {:ok, token_result} = provider.fetch_token(credential_ref, %{scope: scope})
      token_result
    end
  end
end
```

### The Complete `meta_ctx` Shape at Runtime

```elixir
%{
  # From Runic's meta_ref resolution (state_of accumulators)
  fetch_orders__output_state: %{"body" => %{"id" => 123, "status" => "paid"}, ...},
  check_status__output_state: true,

  # From run_context (platform values, set once at workflow start)
  workflow: %{id: "run-uuid", definition_id: "def-uuid", version: 3},
  env: %{"REGION" => "us-east-1"},
  _credential_resolver: #Function<...>,
  _scope: %Fizz.Accounts.Scope{...}
}
```

---

## Validation Boundaries

### Draft Save

Lightweight — accept incomplete work for autosave:

- Ecto embed casting succeeds for `steps`, `connections`, `step_groups`
- Step IDs are unique and key-safe
- Connection IDs are unique
- Every `type_id` exists in `Fizz.Steps.Registry`
- Every connection references existing step IDs
- Every `step_group.step_ids` entry references an existing step
- A step belongs to at most one group
- Graph is acyclic
- Viewport and settings accepted even if incomplete
- **Expressions are NOT parsed** — they may be incomplete

### Publish

Full validation — everything needed for safe compilation:

- All save-time checks pass
- Expressions parse via `Solid.parse/1` with `strict_filters: true`
- Expression references resolve: `{{ steps.foo.body }}` requires step `foo` to exist and be upstream
- Each step's `config` validates against its registered config schema
- Credential references resolve and are accessible to the current scope
- Handle names (`source_output`/`target_input`) are valid for the connected step types
- At least one entry step exists
- **Compilation succeeds** — `Compiler.compile/2` runs to completion
- `compiled_hash` is computed and stored on the version row

### Runtime

No additional validation. The compiled workflow is trusted. Runtime errors (API failures, expression evaluation on unexpected data shapes) are handled by executor return values and Runic's `PolicyDriver` retry policies.

---

## Step Groups in v1

**Completely ignored by the compiler.** Phase 1 (Normalize) strips them. They never enter the IR. The `compiled_hash` does not include them.

Step groups are preserved in the authored document for the editor UI. If a future version gives them execution semantics (error boundaries, retry scopes, sub-workflow boundaries), that would be a new compiler version that reads `step_groups` during assembly and produces different Runic structures.

---

## Compiled Artifact Versioning

```elixir
# On the DefinitionVersion row:
%DefinitionVersion{
  # ... existing fields ...
  compiled_hash: "a1b2c3...",     # SHA-256 of normalized execution content
  compiler_version: 1             # bumped when compiler semantics change
}
```

Add `compiler_version` to the schema. When compiler semantics change (new expression features, different Runic assembly strategy), bump the version. On workflow wake, check compatibility:

```elixir
@current_compiler_version 1

def compatible?(%DefinitionVersion{} = version) do
  version.compiler_version == @current_compiler_version
end
```

If incompatible, recompile from the authored document (which is always preserved as the source of truth).

---

## Integration: Starting a Workflow

```elixir
defmodule Fizz.Workflows.RunWorker do
  def start_workflow(definition_version, input, scope) do
    run_id = Uniq.UUID.uuid7()

    # 1. Compile the authored definition
    {:ok, workflow, compiled_hash} = Compiler.compile(definition_version)

    # 2. Set run_context with platform values
    run_context = Fizz.Workflows.Runtime.ContextBuilder.build_run_context(scope, %{
      run_id: run_id,
      workflow_definition_id: definition_version.workflow_definition_id,
      definition_version: definition_version.version
    })

    workflow = Runic.Workflow.put_run_context(workflow, run_context)

    # 3. Register in Postgres
    {:ok, _run} = Fizz.Workflows.create_workflow_run(run_id, scope, definition_version)

    # 4. Acquire lease
    {:ok, _fence_token} = Fizz.Workflows.LeaseManager.acquire(run_id)

    # 5. Start via Runic Runner
    {:ok, _pid} = Runic.Runner.start_workflow(
      Fizz.Workflows.Runner,
      run_id,
      workflow,
      checkpoint_strategy: :every_cycle,
      hooks: [
        on_complete: &Fizz.Workflows.Hooks.on_step_complete/3,
        on_failed: &Fizz.Workflows.Hooks.on_step_failed/3
      ]
    )

    # 6. Feed initial input
    :ok = Runic.Runner.run(Fizz.Workflows.Runner, run_id, input)

    {:ok, run_id}
  end
end
```

---

## Module Structure

```
lib/fizz/workflows/compiler/
├── compiler.ex                 # Top-level compile/2 entrypoint
├── normalizer.ex               # Phase 1: parse & normalize, strip UI fields
├── expression_compiler.ex      # Phase 2: Liquid → access plans
├── assembler.ex                # Phase 3: IR → %Runic.Workflow{}
├── ir.ex                       # IR structs (Graph, Step, Connection)
└── ir/
    └── access_plan.ex          # AccessPlan structs (Literal, ValueExpression, etc.)

lib/fizz/workflows/runtime/
├── config_resolver.ex          # Resolves access plans at runtime
├── context_builder.ex          # Builds run_context for a workflow execution
└── expression_filters.ex       # Custom Solid filters (Fizz-specific)
```

---

## Key Design Decisions

| Decision | Rationale |
|-|-|
| Access plans compiled at publish time | Avoid re-parsing Liquid on every step execution. Critical for durable workflows that wake from cold storage. |
| Output-capture accumulators for `steps.*` references | Fully native to Runic's graph model. State survives checkpoint/restore. Causality tracked automatically. No mutable context bag. |
| Fast path bypasses Solid for simple dot-access | Most expressions are `{{ steps.x.y.z }}` — direct `get_in` is orders of magnitude faster than template rendering. |
| `run_context` for platform values | Set once at start, flows to all steps via Runic's existing `CausalContext` pipeline. No per-cycle updates needed. |
| Credential refs resolved at runtime, never stored in workflow state | Secrets never enter the fact graph. Provider `fetch_token/2` returns live tokens at execution time. |
| `compiled_hash` excludes UI metadata | UI-only edits (position, notes, groups, viewport) don't produce false version mismatches. |
| Compiler version on definition version row | Enables safe schema evolution. Incompatible versions recompile from the preserved authored document. |
| Step groups stripped in Phase 1 | Clean separation. Future execution semantics for groups would be a new compiler version, not a retrofit. |

---

## Known Gaps & Design Notes

Issues identified during design review that must be resolved before or during implementation.

### 1. Meta-Ref Wiring: The Critical API Gap

**Status: Must resolve before implementation.**

Runic's `state_of(:name)` works via macro detection at step definition time. The `detect_meta_expressions` function in `runic.ex` scans the AST of the work function for calls like `state_of(:counter)` and records them as `meta_refs` on the step struct. During graph wiring, `Component.connect/3` creates `:meta_ref` edges based on these declarations. At runtime, `prepare_meta_context/2` traverses these edges and populates `meta_ctx`.

**The problem:** The Fizz assembler builds work functions programmatically via `Runic.step(fn input, meta_ctx -> ... end)`. If the closure accesses `meta_ctx` via direct map access (not via `state_of()` calls in the AST), the macro won't detect any meta expressions. No `meta_refs` will be recorded, no `:meta_ref` edges will be created, and `meta_ctx` will arrive empty at runtime — silently breaking all expression resolution that depends on upstream step outputs.

**Possible fixes (choose one):**

1. **Generate AST with `state_of()` calls.** Build the work function's quoted expression to include literal `state_of(:fetch_orders__output)` calls so the macro detects them. This requires the assembler to produce quoted AST rather than runtime closures.

2. **Explicit `meta_refs` option on step construction.** Add support in Runic for `Runic.step(work_fn, name: :foo, meta_refs: [%{kind: :state_of, target: :fetch_orders__output, ...}])` so the assembler can declare dependencies without relying on macro detection.

3. **Post-construction mutation.** After creating the step, set `meta_refs` on the struct directly before adding it to the workflow. This is fragile but requires no Runic API changes.

**Recommendation:** Option 2 is the cleanest. It extends Runic's public API to support programmatic graph construction (which is exactly what a compiler needs) without requiring AST generation.

### 2. Accumulator Naming Convention

**Status: Design clarification needed.**

Runic's `state_of(:name)` appends `_state` to produce the `context_key` in `meta_ctx`. The design uses `:"#{step.id}__output"` for accumulator names. Therefore the key in `meta_ctx` will be `:"#{step.id}__output_state"`.

The `build_resolution_context` function constructs this key via string interpolation: `:"#{dep.step_id}__output_state"`. This works, but the `_state` suffix is an implementation detail of Runic's meta-ref system — if Runic changes the suffix convention, the Fizz resolver silently breaks.

**Resolution:** Create a shared helper in the assembler module:

```elixir
defp output_accumulator_name(step_id), do: :"#{step_id}__output"
defp output_context_key(step_id), do: :"#{step_id}__output_state"
```

Use these consistently in both `build_component_pair` and `build_resolution_context`. Consider also having the assembler verify at build time that the expected context keys match what Runic would actually produce.

### 3. False Branch Assembly for Conditions

**Status: Needs implementation detail.**

The design notes that "false branch is a second rule with negated guard" but doesn't show the assembly code. The assembler must:

1. Create two `Runic.rule/1` nodes from a single authored `condition` step — one for the true branch (original predicate), one for the false branch (negated predicate).
2. Name them distinctly (e.g., `:"#{step_id}__true"` and `:"#{step_id}__false"`).
3. Wire downstream steps based on `source_output` handle: connections with `source_output: "true"` attach after the true rule; connections with `source_output: "false"` attach after the false rule.
4. Both rules share the same parent (the upstream step feeding the condition).

```elixir
defp build_condition_rules(%IR.Step{} = ir_step) do
  compiled_config = ir_step.compiled_config
  executor_mod = ir_step.executor

  eval_predicate = fn input, meta_ctx ->
    resolution_ctx = build_resolution_context(input, meta_ctx, ir_step)
    config = ConfigResolver.resolve(compiled_config, resolution_ctx, meta_ctx)
    match?({:ok, true}, executor_mod.execute(config, input, meta_ctx))
  end

  true_rule = Runic.rule(
    name: :"#{ir_step.id}__true",
    condition: fn input, meta_ctx -> eval_predicate.(input, meta_ctx) end,
    reaction: fn input -> input end
  )

  false_rule = Runic.rule(
    name: :"#{ir_step.id}__false",
    condition: fn input, meta_ctx -> not eval_predicate.(input, meta_ctx) end,
    reaction: fn input -> input end
  )

  {true_rule, false_rule}
end
```

The assembler's wiring phase must then match `source_output` handles to the correct rule when adding downstream connections.

### 4. IR Struct Serialization in Closures

**Status: Risk to monitor.**

The work function closure captures `ir_step` (an `%IR.Step{}` struct) in its bindings. When the workflow is checkpointed via `Workflow.log/1`, this struct is serialized as part of the closure's bindings via `:erlang.term_to_binary`. If `%IR.Step{}` gains or removes a field between deploys, deserialized closures from old checkpoints will contain structs that don't match the current definition.

The `compiler_version` check catches this only if someone remembers to bump it for every struct change.

**Mitigation options:**

1. **Extract only needed fields into a plain map before closure capture.** Instead of capturing `ir_step`, capture `%{context_deps: ir_step.context_deps, compiled_config: ir_step.compiled_config}`. Plain maps survive field additions gracefully.

2. **Treat IR structs as internal-only and never capture them in closures.** Pass the resolution context as pre-built data rather than building it inside the closure from IR metadata.

**Recommendation:** Option 1. Extract the specific fields needed by `build_resolution_context` into a plain map at assembly time. This makes the closure bindings independent of IR struct evolution.

### 5. Credential Resolver Serialization

**Status: Must resolve before implementation.**

The `run_context` includes `_credential_resolver`, a closure that captures `scope`. `run_context` flows into `meta_ctx` and is part of the workflow's runtime state. If the workflow is checkpointed and later restored, `run_context` is deserialized from the checkpoint.

The credential resolver closure captures a `%Fizz.Accounts.Scope{}` struct. If `Scope` contains process-bound state (registry refs, connection pools, Ecto repo handles), the deserialized closure will reference dead processes.

**Resolution:** `run_context` must be reconstructed at resume time, not deserialized from the checkpoint. The Store adapter's `load/2` path should:

1. Deserialize the workflow log.
2. Rebuild `run_context` from the workflow run's Postgres metadata (which has `project_id`, `workos_organization_id`, etc.).
3. Call `Workflow.put_run_context/2` with the freshly built context before resuming execution.

This means `run_context` values should be treated as ephemeral — set at start, reconstructed on resume, never relied upon from serialized state. Document this as a platform contract.

### 6. Re-Compilation on Every Start

**Status: Confirmed as correct design.**

The review flagged `Compiler.compile(definition_version)` in `RunWorker.start_workflow/3` as wasteful. This is actually the right choice:

- The compiler is a pure function and compilation is sub-millisecond (AST manipulation, no I/O).
- Re-compiling guarantees the output matches the current compiler version and step registry.
- If a deploy updates an executor module, re-compiling picks up the correct reference.
- Caching compiled artifacts creates a stale-binding problem that's harder to debug.
- The `compiled_hash` serves a different purpose: detecting runtime-equivalent versions, not caching.

No change needed.

### 7. Concurrent Draft Editing

**Status: Accepted limitation for v1.**

The draft lifecycle assumes one mutable draft per definition. Concurrent editors using autosave will produce last-write-wins behavior since each save replaces the full `steps`/`connections`/`step_groups` payload. This is acceptable for v1 but should be documented as an explicit decision in the workflow definition design, not left as an unaddressed gap. See the workflow-definition-design doc for the documented decision.

### 8. ContinueAsNew

**Status: Needs its own design section before Phase 2.**

The fizz-design-plan mentions `ContinueAsNew` for log growth management (50,000 entries or 50 MB) but doesn't design the mechanism. Before Phase 2, document:

- How essential state is identified and carried forward (which accumulators, which pending facts).
- How the parent execution's archive links to the child (Postgres metadata? SQLite cross-reference?).
- Whether the old execution's SQLite file is archived to S3 Glacier or kept warm.
- How the operator console presents the lineage (timeline spanning multiple executions).
