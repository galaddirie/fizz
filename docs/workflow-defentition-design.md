## Workflow Authoring & Definitions

This section defines how authored workflows are stored in Postgres, validated in Ecto, and moved through the draft -> published lifecycle.

### Design Goals

- The `workflow_definitions` row is the stable identity for a workflow.
- `workflow_definition_versions` rows hold draft and published snapshots.
- The version payload should be typed in Elixir, not treated as an opaque `graph` blob.
- The core authored primitives are Ecto embeds: `steps`, `connections`, and `step_groups`.
- Draft saves must accept incomplete work for autosave. Publish must enforce full runtime validity.
- `step_groups` are a UI construct in v1. They may become an execution boundary later, but they do not change execution semantics yet.
- Publishing stores a `compiled_hash` of the normalized executable graph so runtime-equivalent versions are easy to compare and audit.

---

### Naming

- Persisted and API-facing naming should be `step_groups`.
- `groups` and `node_groups` are legacy terms from older code and UI types. Keep them only as temporary compatibility shims at the boundary.
- Rename the old `Fizz.Workflows.Embeds.NodeGroup` concept to `Fizz.Workflows.Embeds.StepGroup`.

---

### Canonical Version Shape

A version snapshot is stored as first-class embedded collections plus small top-level maps for editor metadata:

```json
{
  "steps": [
    {
      "id": "fetch_orders",
      "type_id": "http_request",
      "name": "Fetch Orders",
      "config": {
        "url": "https://api.example.com/orders",
        "method": "GET"
      },
      "position": { "x": 200, "y": 100 },
      "notes": "Pull the latest orders before fan-out."
    },
    {
      "id": "status_ok",
      "type_id": "condition",
      "name": "Status OK?",
      "config": {
        "field": "status",
        "operator": "equals",
        "value": 200
      },
      "position": { "x": 440, "y": 100 }
    },
    {
      "id": "notify_team",
      "type_id": "notify",
      "name": "Notify Team",
      "config": {
        "channel": "email",
        "template_id": "order_summary"
      },
      "position": { "x": 680, "y": 40 }
    }
  ],
  "connections": [
    {
      "id": "fetch_orders__status_ok",
      "source_step_id": "fetch_orders",
      "source_output": "main",
      "target_step_id": "status_ok",
      "target_input": "main"
    },
    {
      "id": "status_ok__notify_team_true",
      "source_step_id": "status_ok",
      "source_output": "true",
      "target_step_id": "notify_team",
      "target_input": "main"
    }
  ],
  "step_groups": [
    {
      "id": "order_checks",
      "name": "Order Checks",
      "step_ids": ["status_ok", "notify_team"],
      "position": { "x": 360, "y": 12, "width": 520, "height": 260 },
      "color": "#f59e0b",
      "font_size": 14,
      "collapsed": false
    }
  ],
  "viewport": { "x": 0, "y": 0, "zoom": 1.0 },
  "settings": {}
}
```

Important: `step_groups` are persisted with the authored document, but in v1 they are editor metadata. The executable graph is derived from `steps` + `connections`.

---

### Data Model

```text
workflow_definitions
- id
- project_id
- workos_organization_id
- name
- description
- created_by_user_id
- archived_at
- inserted_at
- updated_at

workflow_definition_versions
- id
- workflow_definition_id
- version
- status (draft | published | archived)
- steps (jsonb, embeds_many)
- connections (jsonb, embeds_many)
- step_groups (jsonb, embeds_many)
- viewport (jsonb)
- settings (jsonb)
- compiled_hash
- published_at
- published_by_user_id
- inserted_at
- updated_at
```

```sql
CREATE TABLE workflow_definitions (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id              UUID NOT NULL REFERENCES projects(id),
    workos_organization_id  TEXT NOT NULL,
    name                    TEXT NOT NULL,
    description             TEXT NOT NULL DEFAULT '',
    created_by_user_id      TEXT NOT NULL,
    archived_at             TIMESTAMPTZ,
    inserted_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_wf_defs_project_id ON workflow_definitions(project_id);

CREATE TABLE workflow_definition_versions (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workflow_definition_id   UUID NOT NULL REFERENCES workflow_definitions(id) ON DELETE CASCADE,
    version                  INTEGER NOT NULL,
    status                   TEXT NOT NULL DEFAULT 'draft'
                             CHECK (status IN ('draft', 'published', 'archived')),
    steps                    JSONB NOT NULL DEFAULT '[]'::jsonb,
    connections              JSONB NOT NULL DEFAULT '[]'::jsonb,
    step_groups              JSONB NOT NULL DEFAULT '[]'::jsonb,
    viewport                 JSONB NOT NULL DEFAULT '{"x":0,"y":0,"zoom":1.0}'::jsonb,
    settings                 JSONB NOT NULL DEFAULT '{}'::jsonb,
    compiled_hash            TEXT,
    published_at             TIMESTAMPTZ,
    published_by_user_id     TEXT,
    inserted_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (workflow_definition_id, version)
);
CREATE INDEX idx_wf_versions_definition_id ON workflow_definition_versions(workflow_definition_id, version);
CREATE INDEX idx_wf_versions_definition_status ON workflow_definition_versions(workflow_definition_id, status);
```

Notes:
- In Ecto migrations these embedded fields are declared as `:map`; Postgres stores them as `jsonb`.
- `embeds_many` is the right fit here because each version row should be a complete self-contained snapshot.
- `on_replace: :delete` should be used on the embeds so autosave can replace the full collection cleanly.

**Lifecycle rules:**

- Each definition has exactly one mutable draft version at a time.
- Publishing freezes the current draft row and stamps `published_at` / `published_by_user_id`.
- A new draft is created by cloning the latest published version's embedded document.
- Published rows are immutable at the application layer.
- Archiving a definition hides it from normal authoring flows without deleting historical published versions.

---

### Ecto Modeling

Recommended modules:

```elixir
Fizz.Workflows.Definition
Fizz.Workflows.DefinitionVersion
Fizz.Workflows.Embeds.Step
Fizz.Workflows.Embeds.Connection
Fizz.Workflows.Embeds.StepGroup
```

Representative schema:

```elixir
defmodule Fizz.Workflows.DefinitionVersion do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fizz.Workflows.Embeds

  schema "workflow_definition_versions" do
    belongs_to :workflow_definition, Fizz.Workflows.Definition

    field :version, :integer
    field :status, Ecto.Enum, values: [:draft, :published, :archived]

    embeds_many :steps, Embeds.Step, on_replace: :delete
    embeds_many :connections, Embeds.Connection, on_replace: :delete
    embeds_many :step_groups, Embeds.StepGroup, on_replace: :delete

    field :viewport, :map, default: %{"x" => 0, "y" => 0, "zoom" => 1.0}
    field :settings, :map, default: %{}

    field :compiled_hash, :string
    field :published_at, :utc_datetime_usec
    field :published_by_user_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [
      :workflow_definition_id,
      :version,
      :status,
      :viewport,
      :settings,
      :compiled_hash,
      :published_at,
      :published_by_user_id
    ])
    |> validate_required([:workflow_definition_id, :version, :status])
    |> cast_embed(:steps, required: true, with: &Embeds.Step.changeset/2)
    |> cast_embed(:connections, required: true, with: &Embeds.Connection.changeset/2)
    |> cast_embed(:step_groups, with: &Embeds.StepGroup.changeset/2)
    |> validate_embed_id_uniqueness(:steps)
    |> validate_embed_id_uniqueness(:connections)
    |> validate_connection_refs()
    |> validate_step_group_refs()
  end
end
```

The old `Step` and `Connection` embeds can carry over almost unchanged. The main change is that `NodeGroup` becomes `StepGroup`, and we intentionally drop `output_step_id` for v1 because groups are not execution nodes today.

Representative `StepGroup` embed:

```elixir
defmodule Fizz.Workflows.Embeds.StepGroup do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @default_font_size 14

  embedded_schema do
    field :name, :string
    field :step_ids, {:array, :string}, default: []
    field :position, :map, default: %{}
    field :color, :string
    field :font_size, :integer, default: @default_font_size
    field :collapsed, :boolean, default: false
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:id, :name, :step_ids, :position, :color, :font_size, :collapsed])
    |> validate_required([:id, :name])
    |> validate_length(:step_ids, min: 1)
    |> validate_number(:font_size, greater_than_or_equal_to: 10, less_than_or_equal_to: 32)
  end
end
```

---

### Embedded Field Contract

**Step fields**

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Key-safe identifier derived from the current step `name`, used by connections, execution records, and output references. It must be unique within the definition version and is regenerated when the step is renamed. |
| `type_id` | yes | Must match an entry in `Fizz.Steps.Registry`. |
| `name` | yes | User-facing label. |
| `config` | yes | Step-type-specific authored configuration. Compound types can keep nested config here if the nested parts are not graph-connected steps. |
| `position` | no | Canvas coordinates and editor placement metadata. |
| `notes` | no | Freeform author notes. |

**Connection fields**

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Stable connection identifier. |
| `source_step_id` | yes | Upstream step id. |
| `source_output` | no | Output handle name, default `"main"`. |
| `target_step_id` | yes | Downstream step id. |
| `target_input` | no | Input handle name, default `"main"`. |

**Step group fields**

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Stable UI identifier. |
| `name` | yes | Group label. |
| `step_ids` | yes | Step ids contained by the group. |
| `position` | no | Bounding box data such as `x`, `y`, `width`, and `height`. |
| `color` | no | Group color token or raw color string. |
| `font_size` | no | Group label font size. |
| `collapsed` | no | Whether the group is collapsed in the editor. |

### Step ID Semantics

- Step `id` values are generated from the current display `name`, not assigned independently.
- When duplicate names exist, increment the generated id: `"Fetch Order"` -> `fetch_order`, `"Fetch Order 2"` -> `fetch_order_2`.
- Renaming a step regenerates its `id`: `"Fetch Order 2"` -> `fetch_order_2`, then renaming to `"Fetch Order Canada"` updates the `id` to `fetch_order_canada`.
- This is distinct from `type_id`, which identifies the step type from `Fizz.Steps.Registry`. Two renamed HTTP request steps can have different step `id` values while sharing the same `type_id` such as `http_request`.
- A step `id` can match its `type_id`, especially when a step is first created, but they are not the same concept.

Deliberately omitted from `step_groups` in v1:

- `output_step_id`
- synthetic group steps in the execution graph
- any implicit “single output” contract

If step groups become real execution boundaries later, add explicit boundary metadata in a new compiler version rather than retrofitting UI-only fields with runtime meaning.

---

### Validation

Validation should happen in two layers: embed casting in the schema changeset, then cross-document validation in a dedicated validator.

**On save (draft):**

- `cast_embed` succeeds for `steps`, `connections`, and `step_groups`.
- Step ids are unique and key-safe.
- Connection ids are unique.
- Every `type_id` exists in `Fizz.Steps.Registry`.
- Every connection references existing step ids.
- Every `step_group.step_ids` entry references an existing step.
- A step may belong to at most one group in v1.
- The step graph is acyclic.
- Viewport and settings are accepted even if they are incomplete.

**On publish:**

- All save-time checks pass.
- Each step's `config` validates against its registered schema or executor validator.
- Credential references resolve and are accessible to the current scope.
- Handle names such as `source_output` / `target_input` are valid for the connected step types.
- At least one entry step exists.
- The workflow can be compiled into an executable graph.
- `step_groups` still only participate in membership validation unless a future compiler version gives them runtime meaning.

Representative validator shape:

```elixir
defmodule Fizz.Workflows.DefinitionValidator do
  alias Fizz.Steps.Registry
  alias Fizz.Workflows.DefinitionVersion

  def validate_for_save(%DefinitionVersion{} = version) do
    with :ok <- validate_step_types(version.steps),
         :ok <- validate_connection_refs(version.steps, version.connections),
         :ok <- validate_step_group_refs(version.steps, version.step_groups),
         :ok <- validate_non_overlapping_groups(version.step_groups),
         :ok <- validate_acyclic(version.steps, version.connections) do
      :ok
    end
  end

  def validate_for_publish(%DefinitionVersion{} = version, scope) do
    with :ok <- validate_for_save(version),
         :ok <- validate_all_configs(version.steps),
         :ok <- validate_credentials(version.steps, scope),
         :ok <- validate_handles(version.steps, version.connections),
         :ok <- validate_has_entry_step(version.steps, version.connections),
         :ok <- validate_compilable(version.steps, version.connections) do
      :ok
    end
  end

  defp validate_step_types(steps) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      if Registry.exists?(step.type_id),
        do: {:cont, :ok},
        else: {:halt, {:error, {:unknown_type, step.id, step.type_id}}}
    end)
  end
end
```

---

### Draft / Publish Lifecycle

1. Create a `workflow_definitions` row.
2. Create draft version `v1` with empty embedded collections.
3. Autosave draft edits by replacing the full `steps`, `connections`, `step_groups`, `viewport`, and `settings` payload on the draft row.
4. Run lightweight validation on each save.
5. Publish the draft only after full validation succeeds.
6. Compute `compiled_hash` from the normalized executable graph.
7. Stamp `published_at` and `published_by_user_id`.
8. Clone the latest published version into a new draft when further editing starts.

Representative context flow:

```elixir
defmodule Fizz.Workflows.Definitions do
  import Ecto.Query
  import Ecto.Changeset, only: [apply_action: 2]

  alias Fizz.Repo
  alias Fizz.Workflows.{Definition, DefinitionVersion, DefinitionValidator}

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
          steps: [],
          connections: [],
          step_groups: [],
          viewport: %{"x" => 0, "y" => 0, "zoom" => 1.0},
          settings: %{}
        })
        |> Repo.insert()

      {definition, version}
    end)
  end

  def update_draft(version_id, attrs) do
    version = Repo.get!(DefinitionVersion, version_id)

    if version.status != :draft do
      {:error, :not_a_draft}
    else
      changeset = DefinitionVersion.changeset(version, attrs)

      with {:ok, candidate} <- apply_action(changeset, :update),
           :ok <- DefinitionValidator.validate_for_save(candidate) do
        Repo.update(changeset)
      end
    end
  end

  def publish(version_id, scope) do
    version = Repo.get!(DefinitionVersion, version_id)

    if version.status != :draft do
      {:error, :not_a_draft}
    else
      with :ok <- DefinitionValidator.validate_for_publish(version, scope) do
        compiled_hash = compute_compiled_hash(version)

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
end
```

---

### Publishing Sequence

```text
create definition
    |
    v
create draft v1
    |
    v
save draft edits
    |  -- cast embeds
    |  -- validate lightweight graph integrity
    v
publish draft
    |  -- validate configs, credentials, handles, entry step
    |  -- compile executable graph
    |  -- compute compiled_hash from normalized execution payload
    |  -- stamp published_at / published_by_user_id
    v
latest published version
    |
    v
create next draft by cloning embedded document
```

The boundary that matters is still draft vs published. The main change in this design is that the snapshot is typed and validated through Ecto embeds instead of being carried around as a single untyped `graph` map.
