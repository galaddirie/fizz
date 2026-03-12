## Workflow Authoring & Definitions

This section covers how user-authored workflows move from the UI canvas to a persisted JSON definition in Postgres to a live `%Runic.Workflow{}` ready for execution.

### Design Goals

- Users compose workflows visually from the platform's registered step types (`Fizz.Steps.Registry`).
- The canonical representation is a **JSON document** stored in Postgres — portable, inspectable, and diffable.
- A **compiler** transforms the JSON definition into a `%Runic.Workflow{}` at activation time. The JSON is the source of truth; the Runic struct is a derived, ephemeral runtime artifact.
- Definitions support a **draft → published** lifecycle. Published versions are immutable. Running executions pin to a specific published version.

---

### Data Model

```
┌─────────────────────────────────┐       ┌──────────────────────────────────┐
│ workflow_definitions            │       │ workflow_definition_versions      │
│─────────────────────────────────│       │──────────────────────────────────│
│ id (UUID, PK)                   │──┐    │ id (UUID, PK)                    │
│ project_id (FK → projects)      │  │    │ workflow_definition_id (FK) ─────│──┐
│ workos_organization_id          │  │    │ version (integer, monotonic)     │  │
│ name (text)                     │  └───►│ status (draft | published |      │  │
│ description (text)              │       │         archived)                │  │
│ created_by_user_id              │       │ graph (jsonb) ──── the canvas    │  │
│ created_at                      │       │ compiled_hash (text, nullable)   │  │
│ updated_at                      │       │ published_at (timestamptz)       │  │
│ archived_at (timestamptz)       │       │ published_by_user_id             │  │
└─────────────────────────────────┘       │ created_at                       │  │
                                          │ updated_at                       │  │
                                          └──────────────────────────────────┘  │
                                                                                │
                                          ┌──────────────────────────────────┐  │
                                          │ workflow_runs                     │  │
                                          │──────────────────────────────────│  │
                                          │ definition_version_id (FK) ──────│──┘
                                          │ ...                              │
                                          └──────────────────────────────────┘
```

```sql
CREATE TABLE workflow_definitions (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id              UUID NOT NULL REFERENCES projects(id),
    workos_organization_id  TEXT NOT NULL,
    name                    TEXT NOT NULL,
    description             TEXT DEFAULT '',
    created_by_user_id      TEXT NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at             TIMESTAMPTZ
);
CREATE INDEX idx_wf_defs_project ON workflow_definitions(project_id);

CREATE TABLE workflow_definition_versions (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workflow_definition_id   UUID NOT NULL REFERENCES workflow_definitions(id) ON DELETE CASCADE,
    version                  INTEGER NOT NULL,
    status                   TEXT NOT NULL DEFAULT 'draft'
                             CHECK (status IN ('draft', 'published', 'archived')),
    graph                    JSONB NOT NULL DEFAULT '{}',
    compiled_hash            TEXT,
    published_at             TIMESTAMPTZ,
    published_by_user_id     TEXT,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (workflow_definition_id, version)
);
CREATE INDEX idx_wf_versions_def ON workflow_definition_versions(workflow_definition_id, version);
CREATE INDEX idx_wf_versions_status ON workflow_definition_versions(workflow_definition_id, status);
```

**Lifecycle rules:**

- Each definition has at most **one draft** version at a time. The draft is the working copy the UI edits.
- Publishing a draft stamps `published_at`, flips status to `published`, and the `graph` JSONB becomes immutable (enforced at the application layer).
- A new draft is created by cloning the latest published version's graph.
- `workflow_runs.definition_version_id` pins a running execution to the exact version that spawned it. Code evolution (Section 15) validates compatibility at wake time using this FK.

**Ecto schemas:**

```
Fizz.Workflows.Definition
Fizz.Workflows.DefinitionVersion
```

These live alongside the existing `Fizz.Workflows.WorkflowRun` from Section 5.

---

### Graph JSON Schema

The `graph` JSONB column stores the entire canvas state: nodes, edges, viewport metadata. The compiler reads `nodes` and `edges`; the UI owns the rest.

```json
{
  "nodes": [
    {
      "id": "n_01",
      "type_id": "http_request",
      "position": { "x": 200, "y": 100 },
      "config": {
        "url": "https://api.example.com/orders",
        "method": "GET"
      },
      "name": "Fetch Orders"
    },
    {
      "id": "n_02",
      "type_id": "condition",
      "position": { "x": 400, "y": 100 },
      "config": {
        "condition": "{{ json.status }} == 200"
      },
      "name": "Check Status"
    },
    {
      "id": "n_03",
      "type_id": "data_transform",
      "position": { "x": 600, "y": 50 },
      "config": {
        "expression": "json.body.orders"
      },
      "name": "Extract Orders"
    },
    {
      "id": "n_04",
      "type_id": "ai_agent",
      "position": { "x": 600, "y": 200 },
      "config": { "mode": "provider_chat" },
      "name": "Summarize",
      "subnodes": {
        "model": {
          "type_id": "openai_model",
          "config": {
            "model": "gpt-4.1-mini",
            "credential_ref": { "id": "cred_abc", "provider": "openai_api_key" }
          }
        },
        "prompt": {
          "type_id": "ai_prompt_template",
          "config": {
            "system_prompt": "You summarize order data.",
            "user_prompt": "Summarize: {{ json }}"
          }
        }
      }
    }
  ],
  "edges": [
    { "id": "e_01", "source": "n_01", "target": "n_02" },
    { "id": "e_02", "source": "n_02", "target": "n_03", "source_handle": "true" },
    { "id": "e_03", "source": "n_02", "target": "n_04", "source_handle": "false" }
  ],
  "viewport": { "x": 0, "y": 0, "zoom": 1.0 }
}
```

**Node fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Stable client-generated identifier (survives re-ordering). |
| `type_id` | yes | Must match a `Fizz.Steps.Registry` entry. |
| `config` | yes | Validated against `type.config_schema` before publish. |
| `name` | no | User-facing label. |
| `position` | no | Canvas coordinates (UI-only, ignored by compiler). |
| `subnodes` | no | Keyed by slot id from `@subnode_slots`. Each value has `type_id` and `config`. Only for root nodes with `role: :root` that declare subnode slots (e.g. `ai_agent`). |

**Edge fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Stable identifier. |
| `source` | yes | Node id of the upstream node. |
| `target` | yes | Node id of the downstream node. |
| `source_handle` | no | For control-flow nodes: which branch (`"true"`, `"false"`, or switch case labels). |

---

### Validation

Validation runs at two points: on every save (lightweight) and on publish (full).

**On save (draft):**

- `type_id` exists in registry.
- `edges` reference valid node ids.
- No cycles (topological sort must succeed).

**On publish:**

All draft checks, plus:

- `config` validates against `config_schema` for every node (calls `executor.validate_config/1`).
- Required subnode slots are filled.
- Credential refs resolve to live credentials accessible by the project.
- At least one trigger or entry node exists.
- Edge handles match the set emitted by control-flow nodes (e.g. a condition node must have exactly `"true"` and `"false"` handles consumed).

```elixir
defmodule Fizz.Workflows.DefinitionValidator do
  alias Fizz.Steps.Registry

  def validate_for_save(graph) do
    with :ok <- validate_node_types(graph),
         :ok <- validate_edge_refs(graph),
         :ok <- validate_acyclic(graph) do
      :ok
    end
  end

  def validate_for_publish(graph, scope) do
    with :ok <- validate_for_save(graph),
         :ok <- validate_all_configs(graph),
         :ok <- validate_subnode_slots(graph),
         :ok <- validate_credentials(graph, scope),
         :ok <- validate_has_entry_point(graph) do
      :ok
    end
  end

  defp validate_node_types(%{"nodes" => nodes}) do
    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      if Registry.exists?(node["type_id"]),
        do: {:cont, :ok},
        else: {:halt, {:error, {:unknown_type, node["id"], node["type_id"]}}}
    end)
  end

  defp validate_all_configs(%{"nodes" => nodes}) do
    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      type = Registry.get!(node["type_id"])
      module = Fizz.Steps.Type.executor_module!(type)

      case module.validate_config(node["config"] || %{}) do
        :ok -> {:cont, :ok}
        {:error, reasons} -> {:halt, {:error, {:invalid_config, node["id"], reasons}}}
      end
    end)
  end

  # ... remaining validators
end
```

---

### Compiler: JSON → Runic Workflow

The compiler is a pure function: `graph JSON → %Runic.Workflow{}`. It runs at activation time (when a workflow execution starts) and is also invoked for dry-run / preview.

```elixir
defmodule Fizz.Workflows.Compiler do
  @moduledoc """
  Compiles a validated workflow definition graph (JSON) into a
  %Runic.Workflow{} ready for execution by Runic.Runner.

  The compiler:
  1. Topologically sorts nodes.
  2. Builds a Runic component for each node via its executor.
  3. Wires edges as Runic parent-child relationships.
  4. Attaches scheduler policies from step type metadata.
  """

  require Runic
  alias Runic.Workflow
  alias Fizz.Steps.Registry

  @type compile_result :: {:ok, Workflow.t()} | {:error, term()}

  @spec compile(map(), keyword()) :: compile_result()
  def compile(%{"nodes" => nodes, "edges" => edges} = _graph, opts \\ []) do
    with {:ok, sorted_ids} <- topo_sort(nodes, edges),
         {:ok, node_index} <- build_node_index(nodes),
         {:ok, children_map} <- build_children_map(edges),
         {:ok, workflow} <- build_workflow(sorted_ids, node_index, children_map, opts) do
      {:ok, workflow}
    end
  end

  defp build_workflow(sorted_ids, node_index, children_map, opts) do
    name = Keyword.get(opts, :name, "compiled_workflow")

    # Identify root nodes (no incoming edges)
    all_targets = children_map |> Map.values() |> List.flatten() |> MapSet.new()
    root_ids = Enum.reject(sorted_ids, &MapSet.member?(all_targets, &1))

    # Phase 1: Build Runic components for each node, keyed by node id
    components =
      Map.new(sorted_ids, fn id ->
        node = Map.fetch!(node_index, id)
        {id, build_component(node)}
      end)

    # Phase 2: Add to workflow in topological order, wiring edges
    workflow = Workflow.new(name: name)

    workflow =
      Enum.reduce(sorted_ids, workflow, fn id, wf ->
        component = Map.fetch!(components, id)

        if id in root_ids do
          Workflow.add(wf, component)
        else
          # Find parent ids from edges
          parent_ids = find_parents(id, children_map)

          case parent_ids do
            [single_parent] ->
              parent_component = Map.fetch!(components, single_parent)
              Workflow.add(wf, component, to: parent_component)

            multiple_parents ->
              parents = Enum.map(multiple_parents, &Map.fetch!(components, &1))
              Workflow.add(wf, component, to: parents)
          end
        end
      end)

    # Phase 3: Attach scheduler policies
    workflow = attach_policies(workflow, node_index, components)

    {:ok, workflow}
  rescue
    e -> {:error, {:compile_error, e}}
  end

  defp build_component(%{"type_id" => type_id, "config" => config, "id" => id} = node) do
    type = Registry.get!(type_id)
    name = node["name"] || "#{type_id}_#{id}"

    # Delegate to a per-type adapter that knows how to produce the
    # right Runic primitive (step, rule, map, reduce, state_machine, etc.)
    Fizz.Workflows.RunicAdapter.to_runic_component(type, config, name, node)
  end

  defp find_parents(target_id, children_map) do
    for {source_id, targets} <- children_map,
        target_id in targets do
      source_id
    end
  end

  defp build_children_map(edges) do
    map =
      Enum.reduce(edges, %{}, fn edge, acc ->
        Map.update(acc, edge["source"], [edge["target"]], &[edge["target"] | &1])
      end)

    {:ok, map}
  end

  defp build_node_index(nodes) do
    {:ok, Map.new(nodes, fn n -> {n["id"], n} end)}
  end

  defp topo_sort(nodes, edges) do
    graph = :digraph.new()

    try do
      for n <- nodes, do: :digraph.add_vertex(graph, n["id"])
      for e <- edges, do: :digraph.add_edge(graph, e["source"], e["target"])

      case :digraph_utils.topsort(graph) do
        false -> {:error, :cycle_detected}
        sorted -> {:ok, sorted}
      end
    after
      :digraph.delete(graph)
    end
  end

  defp attach_policies(workflow, node_index, components) do
    Enum.reduce(node_index, workflow, fn {id, node}, wf ->
      type = Registry.get!(node["type_id"])
      component = Map.fetch!(components, id)

      # Steps with external I/O get durable retry policies
      policy =
        case type.step_kind do
          :action ->
            %{max_retries: 2, backoff: :exponential, base_delay_ms: 1_000,
              timeout_ms: 30_000, execution_mode: :durable}
          :trigger ->
            %{max_retries: 0, timeout_ms: 60_000, execution_mode: :durable}
          _ ->
            %{max_retries: 0, timeout_ms: 10_000}
        end

      Workflow.add_scheduler_policy(wf, component.name, policy)
    end)
  end
end
```

---

### Runic Adapter: Step Type → Runic Component

Each step type maps to a Runic primitive. Most user-defined steps become `Runic.step/2` wrapping the executor's `execute/3`. Control-flow nodes produce `Runic.rule/1`. Splitter/Aggregator map to `Runic.map/2` and `Runic.reduce/3`.

```elixir
defmodule Fizz.Workflows.RunicAdapter do
  @moduledoc """
  Translates a Fizz step type + user config into a Runic component.
  """

  require Runic
  alias Fizz.Steps.Type

  def to_runic_component(%Type{step_kind: :action} = type, config, name, node) do
    module = Type.executor_module!(type)

    Runic.step(
      fn input, meta_ctx ->
        ctx = Map.get(meta_ctx, :execution_context, %{})
        resolved_config = resolve_expressions(config, input)
        full_input = build_step_input(input, node)
        module.execute(resolved_config, full_input, ctx)
        |> unwrap_step_result()
      end,
      name: name
    )
  end

  def to_runic_component(%Type{step_kind: :transform} = type, config, name, node) do
    module = Type.executor_module!(type)

    Runic.step(
      fn input ->
        resolved_config = resolve_expressions(config, input)
        full_input = build_step_input(input, node)
        module.execute(resolved_config, full_input, %{})
        |> unwrap_step_result()
      end,
      name: name
    )
  end

  def to_runic_component(%Type{step_kind: :control_flow, id: "condition"}, config, name, _node) do
    Runic.rule(
      name: name,
      condition: fn input ->
        resolved = resolve_expressions(config, input)
        Fizz.Steps.Executors.Condition.execute(resolved, input, %{}) == {:ok, input}
      end,
      reaction: fn input -> input end
    )
  end

  def to_runic_component(%Type{step_kind: :control_flow, id: "switch"}, config, name, _node) do
    # Switch produces tagged outputs; the compiler wires edges by handle
    Runic.step(
      fn input ->
        resolved = resolve_expressions(config, input)
        Fizz.Steps.Executors.Switch.execute(resolved, input, %{})
        |> unwrap_step_result()
      end,
      name: name
    )
  end

  def to_runic_component(%Type{id: "splitter"} = type, config, name, _node) do
    module = Type.executor_module!(type)

    Runic.map(
      fn input ->
        {:ok, items} = module.execute(config, input, %{})
        items
      end,
      name: name
    )
  end

  def to_runic_component(%Type{id: "aggregator"}, config, name, _node) do
    op = Map.get(config, "operation", "collect")
    init = Fizz.Steps.Executors.Aggregator.init_for_operation(op)
    reducer = Fizz.Steps.Executors.Aggregator.reducer_for_operation(op)

    Runic.reduce(init, reducer, name: name)
  end

  # Fallback: wrap any executor as a step
  def to_runic_component(%Type{} = type, config, name, node) do
    module = Type.executor_module!(type)

    Runic.step(
      fn input ->
        resolved_config = resolve_expressions(config, input)
        full_input = build_step_input(input, node)
        module.execute(resolved_config, full_input, %{})
        |> unwrap_step_result()
      end,
      name: name
    )
  end

  # --- Helpers ---

  defp unwrap_step_result({:ok, result}), do: result
  defp unwrap_step_result({:error, reason}), do: raise("Step failed: #{inspect(reason)}")
  defp unwrap_step_result({:skip, _reason}), do: nil

  defp resolve_expressions(config, input) when is_map(config) do
    Map.new(config, fn
      {k, v} when is_binary(v) -> {k, interpolate(v, input)}
      {k, v} when is_map(v)    -> {k, resolve_expressions(v, input)}
      {k, v}                   -> {k, v}
    end)
  end

  defp interpolate(template, data) do
    Regex.replace(~r/\{\{\s*([a-zA-Z0-9_\.]+)\s*\}\}/, template, fn _, path ->
      path
      |> String.split(".")
      |> get_in_path(data)
      |> to_string()
    end)
  end

  defp get_in_path([], value), do: value
  defp get_in_path([key | rest], map) when is_map(map), do: get_in_path(rest, Map.get(map, key))
  defp get_in_path(_, _), do: ""

  defp build_step_input(input, %{"subnodes" => subnodes}) when is_map(subnodes) do
    # Root nodes with subnodes: assemble the subnode outputs into the
    # input map under their slot keys, alongside `_primary` for upstream data
    subnode_outputs =
      Map.new(subnodes, fn {slot_id, subnode_def} ->
        type = Fizz.Steps.Registry.get!(subnode_def["type_id"])
        module = Type.executor_module!(type)
        {:ok, output} = module.execute(subnode_def["config"] || %{}, input, %{})
        {slot_id, output}
      end)

    Map.put(subnode_outputs, "_primary", input)
  end

  defp build_step_input(input, _node), do: input
end
```

---

### Draft / Publish Lifecycle

```elixir
defmodule Fizz.Workflows.Definitions do
  alias Fizz.Repo
  alias Fizz.Workflows.{Definition, DefinitionVersion, DefinitionValidator}

  @doc "Create a new definition with an empty draft v1."
  def create(project_id, attrs, user_id) do
    Repo.transaction(fn ->
      {:ok, definition} =
        %Definition{}
        |> Definition.changeset(Map.merge(attrs, %{
          project_id: project_id,
          created_by_user_id: user_id
        }))
        |> Repo.insert()

      {:ok, version} =
        %DefinitionVersion{}
        |> DefinitionVersion.changeset(%{
          workflow_definition_id: definition.id,
          version: 1,
          status: :draft,
          graph: %{"nodes" => [], "edges" => [], "viewport" => %{"x" => 0, "y" => 0, "zoom" => 1}}
        })
        |> Repo.insert()

      {definition, version}
    end)
  end

  @doc "Update the draft version's graph. Runs lightweight validation."
  def update_draft(version_id, graph) do
    version = Repo.get!(DefinitionVersion, version_id)

    if version.status != :draft do
      {:error, :not_a_draft}
    else
      with :ok <- DefinitionValidator.validate_for_save(graph) do
        version
        |> DefinitionVersion.changeset(%{graph: graph, updated_at: DateTime.utc_now()})
        |> Repo.update()
      end
    end
  end

  @doc "Publish the current draft. Full validation. Freezes the graph."
  def publish(version_id, scope) do
    version = Repo.get!(DefinitionVersion, version_id)

    if version.status != :draft do
      {:error, :not_a_draft}
    else
      with :ok <- DefinitionValidator.validate_for_publish(version.graph, scope) do
        compiled_hash = :erlang.phash2(version.graph) |> to_string()

        version
        |> DefinitionVersion.changeset(%{
          status: :published,
          published_at: DateTime.utc_now(),
          published_by_user_id: scope.user.id,
          compiled_hash: compiled_hash
        })
        |> Repo.update()
      end
    end
  end

  @doc "Create a new draft from the latest published version."
  def create_new_draft(definition_id) do
    latest_published =
      DefinitionVersion
      |> where(workflow_definition_id: ^definition_id, status: :published)
      |> order_by(desc: :version)
      |> limit(1)
      |> Repo.one()

    case latest_published do
      nil ->
        {:error, :no_published_version}

      published ->
        next_version = published.version + 1

        %DefinitionVersion{}
        |> DefinitionVersion.changeset(%{
          workflow_definition_id: definition_id,
          version: next_version,
          status: :draft,
          graph: published.graph
        })
        |> Repo.insert()
    end
  end

  @doc "Compile a published version into a Runic workflow for execution."
  def compile_version(version_id, opts \\ []) do
    version = Repo.get!(DefinitionVersion, version_id)

    if version.status != :published do
      {:error, :not_published}
    else
      Fizz.Workflows.Compiler.compile(version.graph, opts)
    end
  end
end
```

---

### Integration with Execution (Section 6–7)

When `Fizz.Workflows.start_workflow/4` is called for a user-authored definition, the flow is:

```
publish version
    │
    ▼
start_workflow(project_id, :user_defined, %{version_id: v_id}, opts)
    │
    ▼
Definitions.compile_version(v_id)
    │  ── JSON graph → Runic.Workflow
    ▼
Fizz.Workflows.start_workflow/4 (existing flow from Section 6.3)
    │  ── registers in workflow_runs with definition_version_id
    │  ── acquires lease, starts Runner worker
    ▼
Runic.Runner.Worker executes compiled workflow
```

The `workflow_runs` row stores `definition_version_id` so that on wake-from-passivation or crash recovery, the system can:

1. Load the Runic log from SQLite/S3 (execution state).
2. Verify the definition version is still compatible (Section 15).
3. Resume via `Runic.Runner.resume/3`.

If the definition's compiled Runic workflow needs to be rebuilt (e.g., after a code deploy changes an executor), the system recompiles from the frozen JSON graph of the pinned version — never from the current draft.

---

### Subnode Assembly for AI Agent Steps

Root nodes like `ai_agent` declare `@subnode_slots` (model, prompt, tools). In the JSON graph, these are nested under the root node's `subnodes` key rather than appearing as separate canvas nodes. The compiler handles assembly:

```json
{
  "id": "n_10",
  "type_id": "ai_agent",
  "config": { "mode": "provider_chat" },
  "subnodes": {
    "model": {
      "type_id": "openai_model",
      "config": { "model": "gpt-4.1-mini", "credential_ref": { ... } }
    },
    "prompt": {
      "type_id": "ai_prompt_template",
      "config": { "system_prompt": "...", "user_prompt": "..." }
    },
    "tools": [
      {
        "type_id": "ai_tool_http",
        "config": { "name": "search", "url": "https://..." }
      }
    ]
  }
}
```

The `RunicAdapter.build_step_input/2` function executes each subnode's executor inline before calling the root executor, matching the slot-injection pattern that `AIAgent.execute/3` already expects.

---

### Compiled Hash & Cache

The `compiled_hash` on a published version is a content hash of the `graph` JSONB. This enables:

- **Compilation caching**: Before compiling, check an ETS/process cache keyed by `{version_id, compiled_hash}`. If the compiled `%Workflow{}` is already cached, skip recompilation.
- **Change detection**: If two sequential publishes produce the same `compiled_hash`, the runtime can reuse the existing compiled artifact.
- **Audit**: The hash is logged alongside `workflow_runs` for traceability.

```elixir
defmodule Fizz.Workflows.CompilerCache do
  @cache_table :workflow_compiler_cache

  def get_or_compile(version_id, compiled_hash, compile_fn) do
    case :ets.lookup(@cache_table, {version_id, compiled_hash}) do
      [{_, workflow}] -> {:ok, workflow}
      [] ->
        case compile_fn.() do
          {:ok, workflow} = result ->
            :ets.insert(@cache_table, {{version_id, compiled_hash}, workflow})
            result
          error -> error
        end
    end
  end
end
```

---

### Expression Resolution

Step configs contain `{{ path.to.field }}` template expressions that reference upstream output. These are resolved at runtime by the Runic adapter before passing config to the executor. The resolution happens inside the Runic step's work function, which receives the upstream fact value as input.

This is a string interpolation pass — not a full expression evaluator. For v1, supported syntax is:

- `{{ json }}` — the entire input value (serialized if non-string)
- `{{ json.field }}` — dot-path access into a map
- `{{ json.field.nested }}` — multi-level dot-path

The word `json` is a convention matching the n8n-style model where each node's output is a JSON object. In Runic terms, `json` is the raw value of the input `%Fact{}`.

Future iterations can introduce a richer expression language (comparisons, arithmetic, function calls) as a separate `Fizz.Workflows.ExpressionEngine` module, keeping the compiler and adapter unchanged.