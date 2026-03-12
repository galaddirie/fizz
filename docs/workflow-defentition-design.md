## Workflow Authoring & Definitions

This section focuses on the authored workflow document, how it is stored in Postgres, and how it moves through the draft -> published lifecycle.

### Design Goals

- Users compose workflows visually from the platform's registered step types (`Fizz.Steps.Registry`).
- The canonical representation is a JSON document stored in Postgres: portable, inspectable, and diffable.
- The definition record is the stable identity for a workflow; version rows hold draft and published snapshots of the graph.
- Editing always happens against a draft. Publishing freezes an immutable snapshot.
- Publishing also records a computed hash for the frozen graph so identical snapshots are easy to detect and audit.
- Save and publish have different validation strictness so the canvas can autosave incomplete work without lowering publish quality.

---

### Data Model

```
┌─────────────────────────────────┐       ┌──────────────────────────────────┐
│ workflow_definitions            │       │ workflow_definition_versions     │
│─────────────────────────────────│       │──────────────────────────────────│
│ id (UUID, PK)                   │──┐    │ id (UUID, PK)                    │
│ project_id (FK -> projects)     │  │    │ workflow_definition_id (FK)  ────│──┐
│ workos_organization_id          │  │    │ version (integer, monotonic)     │  │
│ name (text)                     │  └───►│ status (draft | published |      │  │
│ description (text)              │       │         archived)                │  │
│ created_by_user_id              │       │ graph (jsonb)                    │  │
│ created_at                      │       │ compiled_hash (text, nullable)   │  │
│ updated_at                      │       │ published_at (timestamptz)       │  │
│ archived_at (timestamptz)       │       │ published_by_user_id             │  │
└─────────────────────────────────┘       │ created_at                       │  │
                                          │ updated_at                       │  │
                                          └──────────────────────────────────┘  │
                                                                                │
                                          ┌──────────────────────────────────┐  │
                                          │ workflow_runs                    │  │
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

- Each definition has at most one draft version at a time. The draft is the working copy the UI edits.
- Publishing a draft stamps `published_at`, flips status to `published`, and makes that version's `graph` immutable at the application layer.
- Publishing also computes and stores `compiled_hash` from the frozen graph snapshot.
- A new draft is created by cloning the latest published version's graph.
- The `workflow_definitions` row is the long-lived identity and metadata container. The `workflow_definition_versions` rows are the versioned content.
- Archiving a definition hides it from normal authoring flows without destroying prior published history.

**Ecto schemas:**

```elixir
Fizz.Workflows.Definition
Fizz.Workflows.DefinitionVersion
```

---

### Graph JSON Schema

The `graph` JSONB column stores the full canvas payload: nodes, edges, viewport metadata, and any other editor-owned fields that should travel with the draft or published version.

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
      "position": { "x": 420, "y": 100 },
      "config": {
        "field": "status",
        "operator": "equals",
        "value": 200
      },
      "name": "Status OK?"
    },
    {
      "id": "n_03",
      "type_id": "notify",
      "position": { "x": 640, "y": 50 },
      "config": {
        "channel": "email",
        "template_id": "order_summary"
      },
      "name": "Notify Team"
    },
    {
      "id": "n_04",
      "type_id": "ai_agent",
      "position": { "x": 640, "y": 220 },
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
            "user_prompt": "Summarize the latest order payload."
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
| `id` | yes | Stable client-generated identifier that survives reordering. |
| `type_id` | yes | Must match a `Fizz.Steps.Registry` entry. |
| `config` | yes | User-authored configuration payload for that step type. |
| `name` | no | User-facing label. |
| `position` | no | Canvas coordinates and similar editor-owned metadata. |
| `subnodes` | no | Nested configuration for compound root nodes such as `ai_agent`. |

**Edge fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Stable identifier. |
| `source` | yes | Node id of the upstream node. |
| `target` | yes | Node id of the downstream node. |
| `source_handle` | no | Branch identifier for control-flow nodes such as `"true"` / `"false"`. |

**Subnodes:**

- Compound nodes keep nested step configuration under `subnodes` so the authored document still reflects a single canvas node.
- Required subnode slots are part of publish-time validation.
- Subnodes are versioned with their parent node because they live inside the same `graph` snapshot.

---

### Validation

Validation runs at two points: on every save (lightweight) and on publish (full).

**On save (draft):**

- `type_id` exists in the registry.
- `edges` reference valid node ids.
- No cycles.

**On publish:**

All draft checks, plus:

- `config` validates against the step type's config schema.
- Required subnode slots are filled.
- Credential refs resolve to credentials accessible to the project.
- At least one entry node exists.
- Control-flow handles are valid for the connected node type.

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

### Draft / Publish Lifecycle

```elixir
defmodule Fizz.Workflows.Definitions do
  import Ecto.Query

  alias Fizz.Repo
  alias Fizz.Workflows.{Definition, DefinitionVersion, DefinitionValidator}

  @doc "Create a new definition with an empty draft v1."
  def create(project_id, attrs, user_id) do
    Repo.transaction(fn ->
      {:ok, definition} =
        %Definition{}
        |> Definition.changeset(
          Map.merge(attrs, %{
            project_id: project_id,
            created_by_user_id: user_id
          })
        )
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
end
```

---

### Publishing Sequence

```
create definition
    │
    ▼
create draft v1
    │
    ▼
save draft edits
    │  ── lightweight validation
    ▼
publish draft
    │  ── full validation
    │  ── compute compiled_hash from frozen graph
    │  ── stamp published_at / published_by_user_id
    │  ── freeze version graph
    ▼
latest published version
    │
    ▼
create next draft by cloning latest published graph
```

The important boundary is that drafts are mutable working copies and published versions are immutable snapshots. Any further editing happens in a new draft, never by mutating an already published row.

`compiled_hash` stays attached to the published snapshot, not the mutable definition record, because it describes that exact frozen version of the graph.
