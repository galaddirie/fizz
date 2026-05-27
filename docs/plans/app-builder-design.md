# App Builder Platform Design

> Full vision document for transforming Fizz from a workflow orchestration platform into an app-building platform where users can model backends as workflows and build real-time UIs, dashboards, chat apps, and interactive tools.

## Vision

Users build workflows today. With the app builder, those workflows become **applications** — shareable, interactive, real-time experiences backed by durable execution. A user could wire up an AI agent workflow, attach a chat UI, publish it to a URL, and share it with their team. Or build a dashboard that queries APIs on a schedule, stores data in tables, and renders live charts.

The key insight: **we don't build a separate app builder**. We add four primitive layers to the existing workflow engine, each independently useful but composing together to enable increasingly powerful apps.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  LAYER 4: APP SHELL & DEPLOYMENT                        │
│  Published URLs · Embedded widgets · Auth gates · Apps   │
├─────────────────────────────────────────────────────────┤
│  LAYER 3: UI PRIMITIVES (Render Steps)                  │
│  Display: Table, Chart, Markdown, Metric, Image         │
│  Input:   Form, ButtonGroup, ChatInput, Slider          │
│  Layout:  Page, Grid, Tabs, Sidebar, Stack, Columns     │
├─────────────────────────────────────────────────────────┤
│  LAYER 2: INTERACTION PRIMITIVES                        │
│  Human-in-the-Loop: wait_for_input, wait_for_approval   │
│  Real-time: channels, streaming, presence, typing       │
├─────────────────────────────────────────────────────────┤
│  LAYER 1: STATE PRIMITIVES                              │
│  Key-Value Store: get/set/delete/increment/CAS          │
│  Structured Tables: user-defined schemas, CRUD, queries │
├─────────────────────────────────────────────────────────┤
│  EXISTING FOUNDATION (Already Built)                    │
│  Durable Execution · Signals · Timers · Triggers ·      │
│  Expressions · 55+ Step Types · Multi-tenant            │
└─────────────────────────────────────────────────────────┘
```

## What This Enables

| App Type | Layers Used | Example |
|----------|-------------|---------|
| Dashboard | L1 (tables) + L3 (chart/table/metric) + L4 (published URL) | Schedule trigger → fetch API → store in table → render chart + metrics |
| Approval Flow | L2 (wait_for_approval) + L3 (form) + L4 (auth) | Form trigger → validate → wait_for_approval → notify → write to table |
| AI Chat App | L1 (KV for history) + L2 (streaming + chat) + L3 (chat UI) + L4 (shared URL) | Chat trigger → AI agent → stream response → wait for reply → loop |
| Interactive Game | L1 (KV for state) + L2 (channels) + L3 (buttons + grid) + L4 (public URL) | Button click → update game state in KV → render board → real-time sync |

---

## Layer 1: State Primitives

Persistent storage that workflows can read/write, surviving beyond individual runs.

### Key-Value Store

Per-project namespaced key-value storage. Simple get/set/delete/list with atomic operations for counters and game state.

**Schemas:**

```
app_kv_namespaces
  id                     :binary_id PK
  project_id             :binary_id FK
  workos_organization_id :string
  name                   :string        -- e.g. "default", "game_state", "prefs"
  description            :string
  entry_count            :integer       -- denormalized for quota checks
  total_bytes            :integer       -- denormalized for quota checks
  timestamps()

  unique: [:project_id, :name]
```

```
app_kv_entries
  id            :binary_id PK
  namespace_id  :binary_id FK -> app_kv_namespaces
  key           :string
  value         :map          -- JSONB, stores any JSON-serializable value
  value_type    :string       -- "string" | "integer" | "float" | "boolean" | "json" | "null"
  version       :integer      -- monotonic, for compare-and-swap
  expires_at    :utc_datetime -- optional TTL
  size_bytes    :integer      -- computed on write for quota tracking
  timestamps()

  unique: [:namespace_id, :key]
  index: [:namespace_id, :expires_at] (partial, where expires_at IS NOT NULL)
```

**Design decisions:**
- `value_type` discriminator preserves integer/boolean fidelity through JSONB round-trips
- `version` is monotonic, incremented on every write — enables CAS via `WHERE version = :expected`
- Denormalized counters on namespace updated atomically with writes via `Repo.update_all(inc: [...])`
- TTL cleanup via periodic Oban worker (`Fizz.AppState.Workers.KvTtlSweeper`)

### Structured Tables

User-defined schemas (Airtable-style) with CRUD operations, filtering, and sorting.

**Schemas:**

```
app_tables
  id                     :binary_id PK
  project_id             :binary_id FK
  workos_organization_id :string
  name                   :string
  slug                   :string        -- for expression references
  description            :string
  column_schema          {:array, :map} -- ordered column definitions
  row_count              :integer       -- denormalized
  total_bytes            :integer       -- denormalized
  timestamps()

  unique: [:project_id, :slug]
```

Column schema format:
```json
{
  "id": "col_uuid",
  "name": "Email",
  "slug": "email",
  "type": "string",
  "required": false,
  "default": null,
  "unique": false
}
```

Supported column types: `string`, `integer`, `float`, `boolean`, `datetime`, `json`

```
app_table_rows
  id         :binary_id PK
  table_id   :binary_id FK -> app_tables
  data       :map          -- JSONB keyed by column slug
  sort_order :integer      -- user-defined ordering
  size_bytes :integer
  timestamps()

  GIN index on data (for @> containment queries)
  index: [:table_id, :sort_order]
  index: [:table_id, :inserted_at]
```

**Design decisions:**
- Column schema lives in JSONB on the table record (not a separate columns table) — keeps reads as single queries, trivial reordering
- Schema validation at application layer, not Postgres constraints — column schemas change frequently
- Row data is flat JSONB keyed by column slug: `%{"email" => "a@b.com", "age" => 30}`
- Filtered queries use JSONB `@>` containment or `->>` text comparison via dynamic Ecto query building

### Step Types

Category: `"App State"`

| Step ID | Kind | Description |
|---------|------|-------------|
| `kv_get` | `:action` | Read a key from a KV namespace |
| `kv_set` | `:action` | Write a key (with optional TTL) |
| `kv_delete` | `:action` | Delete a key |
| `kv_list` | `:action` | List keys (with optional prefix filter) |
| `kv_increment` | `:action` | Atomically increment a numeric value |
| `kv_compare_and_swap` | `:action` | CAS: update only if version matches |
| `table_query` | `:action` | Query rows with filters, sort, pagination |
| `table_insert` | `:action` | Insert one or more rows |
| `table_update` | `:action` | Update rows matching a filter |
| `table_delete` | `:action` | Delete rows matching a filter |
| `table_get_row` | `:action` | Get single row by ID |
| `table_upsert` | `:action` | Insert or update based on unique column |

All executors follow existing patterns: `use Fizz.Integrations.StepDefinition`, `@behaviour Fizz.Workflows.StepExecutor`, typed `@fields`, and `execute/3`. They call `Fizz.AppState` context functions, receiving `org_id` and `project_id` from `context[:metadata]`.

`kv_increment` uses atomic SQL: `UPDATE ... SET value = value + $amount, version = version + 1 ... RETURNING *` with upsert for non-existent keys.

`kv_compare_and_swap` uses `WHERE version = $expected_version`, returns `{:error, :version_mismatch}` on conflict.

### Expression Integration

Add a `"store"` binding to the expression context so workflows can reference KV values inline:

```
{{ store.default.my_key }}
{{ store.game_state.score }}
```

Implementation: `Fizz.AppState.LazyStoreAccess` struct implements Solid's access protocol. Injected into `base_context/1` in `ContextBuilder`. When accessed, triggers `Fizz.AppState.kv_get/4`.

Table data is accessed via step outputs (`{{ steps.my_query.rows }}`) rather than direct expression binding — step-based access is cleaner for collections.

### Real-Time Change Notifications

PubSub topics:
```
app_state:kv:{project_id}                    -- all KV changes
app_state:kv:{project_id}:{namespace}        -- namespace-scoped
app_state:table:{project_id}:{table_id}      -- row changes
```

Event structs:
- `Fizz.AppState.Events.KvChanged` — `action`, `namespace`, `key`, `value`, `version`, `project_id`
- `Fizz.AppState.Events.TableRowChanged` — `action`, `table_id`, `table_slug`, `row_id`, `data`, `project_id`

Broadcast from context module after every mutation. Channel `FizzWeb.AppStateChannel` (topic `app_state:*`) forwards events to connected browser clients.

### Context Module: `Fizz.AppState`

Located at `lib/fizz/app_state.ex`. Two calling conventions:
- **Scope-based** for management (create/delete namespace/table) — from LiveViews, includes auth checks
- **Raw ID-based** for data ops (kv_get/set, table_insert/query) — from step executors, auth already verified at run creation

### Storage Quotas

```elixir
config :fizz, Fizz.AppState,
  kv_max_namespaces_per_project: 20,
  kv_max_entries_per_namespace: 10_000,
  kv_max_value_bytes: 256_000,                  # 256 KB per value
  kv_max_total_bytes_per_project: 52_428_800,   # 50 MB
  table_max_tables_per_project: 50,
  table_max_rows_per_table: 100_000,
  table_max_columns_per_table: 100,
  table_max_row_bytes: 1_048_576,               # 1 MB per row
  table_max_total_bytes_per_project: 524_288_000 # 500 MB
```

Enforced by `Fizz.AppState.Quota` module, checked on every write. Uses denormalized counters for O(1) checks.

---

## Layer 2: Interaction Primitives

Bidirectional communication between running workflows and human users.

### Core Architecture

Two subsystems sharing infrastructure:

1. **Human-in-the-Loop (HitL)** — built on the existing `signal_inbox` + `DurableTimer` machinery. A new executor return convention `{:wait_for_signal, signal_key, interaction_spec, output}` parks the run in SLEEPING status. User input arrives as a signal through `SignalRouter`, which already handles passivation/rehydration.

2. **Real-time Channels** — a new Phoenix Channel (`FizzWeb.WorkflowRunChannel`) subscribes to the existing `"workflow_run:#{run_id}"` PubSub topic. Adds streaming, bidirectional client events, presence, and typing indicators.

### Interaction Requests Table

Durable state for what the run is waiting for. Sits alongside `signal_inbox` and `durable_timers`.

```
interaction_requests
  id                     :binary_id PK
  run_id                 :binary_id FK -> workflow_runs
  project_id             :binary_id FK
  workos_organization_id :string
  step_id                :string        -- which step created this
  interaction_id         :string        -- unique key, also the signal_key
  kind                   :string        -- "input" | "approval" | "chat_reply"
  status                 :string        -- "pending" | "submitted" | "expired" | "cancelled"
  ui_spec                :map           -- form descriptor for the client
  prompt                 :string        -- human-readable prompt text
  metadata               :map           -- extra context (approver list, timeout, etc.)
  response               :map           -- filled on submission
  submitted_by           :string        -- user ID
  submitted_at           :utc_datetime
  expires_at             :utc_datetime  -- optional deadline
  timestamps()

  unique: [:run_id, :interaction_id]
  index: [:run_id, :status]
  index: [:project_id, :status]  -- for org-wide pending approval dashboards
```

Why not reuse `signal_inbox`: interaction requests carry UI metadata (form schema, prompt, approval config) that must be queryable **before** the signal arrives. The signal_inbox remains the delivery mechanism.

### Worker Changes: Signal Intent

New executor return convention:
```elixir
{:wait_for_signal, signal_key, interaction_spec, passthrough_output}
```

Where `interaction_spec`:
```elixir
%{
  kind: "input" | "approval" | "chat_reply",
  ui_spec: %{...},
  prompt: "Please approve this order",
  metadata: %{...},
  expires_in_ms: nil | integer
}
```

In `Runner.Worker`, add `signal_intent/1` alongside existing `timer_intent/1`:

```elixir
defp signal_intent(%Runnable{
       result: %Fact{value: {:wait_for_signal, signal_key, interaction_spec, output}},
       node: node
     }) do
  step_id = to_string(Map.get(node, :name))
  {:ok, %{signal_key: signal_key, interaction_spec: interaction_spec, output: output, step_id: step_id}}
end
defp signal_intent(_runnable), do: :none
```

`handle_signal_intent/3`:
1. Creates `interaction_request` row
2. Optionally creates `DurableTimer` for timeout
3. Transitions run to SLEEPING
4. Broadcasts `{:interaction_requested, payload}` on PubSub

### Signal Delivery Path (User Submission)

```
Browser client
  → WorkflowRunChannel.handle_in("submit_input", ...)
  → Fizz.Workflows.Interactions.submit_response(run_id, interaction_id, response, user_id)
    1. Update interaction_request: status → "submitted", response → data
    2. SignalRouter.accept_signal(run_id, interaction_id, response)
       → If worker alive: deliver immediately
       → If passivated: rehydrate from S3, then deliver
    3. Cancel timeout timer if present
    4. Broadcast {:interaction_submitted, ...}
```

### Step Types

Category: `"Interaction"`

| Step ID | Kind | Description |
|---------|------|-------------|
| `wait_for_input` | `:action` | Pause and wait for user to submit data via a form |
| `wait_for_approval` | `:action` | Pause until one or more users approve |
| `send_to_client` | `:action` | Push a message to connected clients (no pause) |
| `request_input` | `:action` | Send a message and wait for reply (chat turn) |

**wait_for_approval** supports parallel approval (3-of-5): creates N interaction_request rows with a shared prefix. Individual approvals are recorded; when threshold is met, the final signal is inserted into `signal_inbox`.

**request_input** is the chat turn primitive: sends outgoing message (broadcast + persist to `chat_messages`), then returns `{:wait_for_signal, ...}` to wait for reply.

### Chat Messages Table

For durable chat session history:

```
chat_messages
  id                     :binary_id PK
  run_id                 :binary_id FK -> workflow_runs
  project_id             :binary_id FK
  workos_organization_id :string
  direction              :string        -- "incoming" | "outgoing"
  content                :text
  content_type           :string        -- "text" | "markdown" | "json"
  sender_type            :string        -- "user" | "workflow" | "system"
  sender_id              :string        -- user_id or step_id
  interaction_id         :string        -- links to interaction_request
  metadata               :map           -- attachments, tool calls, etc.
  read_by                :map           -- %{user_id => read_at}
  inserted_at            :utc_datetime

  index: [:run_id, :inserted_at]
  index: [:run_id, :interaction_id]
```

Chat workflow cycle:
```
[on_chat_trigger] → [ai_agent] → [request_input] → [ai_agent] → [request_input] → ...
```

The workflow graph uses loop edges. `request_input` is the durable pause point. On passivation, full chat history is in `chat_messages` (Postgres), so the AI agent can rebuild context on rehydration.

### Real-Time Channel

`FizzWeb.WorkflowRunChannel` on topic `"workflow_run:{run_id}"`:

**Join:** Validates access, subscribes to PubSub, tracks presence, sends current state (pending interactions + recent chat messages).

**Client → Server:**
- `submit_input` — routes user form/approval/chat response through `Interactions.submit_response`
- `chat_message` — finds pending chat interaction, submits response
- `typing` — broadcasts typing indicator to other clients via `broadcast_from!`

**Server → Client (via PubSub forwarding):**
- `interaction_requested` — new interaction waiting for user
- `interaction_submitted` — interaction completed
- `chat_message` — incoming/outgoing chat messages
- `stream_chunk` — AI token-by-token streaming
- `stream_complete` — streaming finished with full output
- `run_status_changed`, `step_started`, `step_completed`, `step_failed`

### Streaming Architecture

New optional callback on executor behaviour:

```elixir
@callback execute_streaming(config, input, context, stream_callback :: (chunk -> :ok)) ::
            {:ok, output} | {:error, reason}
@optional_callbacks [execute_streaming: 4]
```

When the Worker dispatches a runnable for a streaming-capable step (detected via `function_exported?/3`), it provides a callback that broadcasts `{:stream_chunk, %{step_id, chunk, timestamp}}` on PubSub. The channel forwards chunks to the browser. When streaming completes, the executor returns the full output normally.

The stream_callback runs in the Task process (not the Worker GenServer), which is safe for PubSub broadcasts.

### Presence and Typing

- `FizzWeb.Presence` (already exists) tracks users per run topic
- Typing indicators are ephemeral — `broadcast_from!` only, no persistence
- "AI is thinking" indicator: implicit from `stream_chunk` events arriving; explicit from `step_started` → `step_completed` window

### Context Module: `Fizz.Workflows.Interactions`

```elixir
# Interaction Requests
create_interaction_request(run_id, attrs)
submit_response(run_id, interaction_id, response, user_id)
list_pending(run_id)
find_pending_chat_interaction(run_id)
cancel_interaction(interaction_id)
expire_stale_interactions()

# Chat Messages
append_chat_message(run_id, attrs)
list_recent_chat_messages(run_id, opts)
mark_message_read(message_id, user_id)
chat_history_for_context(run_id, opts)  -- formats for LLM context

# Approvals
record_approval(run_id, interaction_id, user_id, decision)
check_approval_threshold(run_id, interaction_id)
```

---

## Layer 3: UI Primitives (Render Steps)

New step types whose output is a **renderable UI descriptor** — the "Kino for Fizz".

### UI Descriptor Format

```json
{
  "$ui": "1.0",
  "type": "<component_type>",
  "props": { ... },
  "children": [ ... ],
  "signal_key": "optional, for input components",
  "awaiting_input": false
}
```

The `$ui` field distinguishes UI descriptors from plain data output. When `step_completed` fires with `output.$ui`, the client renders it as a visual component instead of raw data.

### Component Taxonomy

**Display components:**

| Type | Props |
|------|-------|
| `table` | `columns: [{key, label, sortable?, format?}], rows: [{}], pagination?: {page, per_page, total}` |
| `chart` | `chart_type: "line"\|"bar"\|"pie"\|"area", data: {labels, datasets}, options?: {}` |
| `markdown` | `content: string` |
| `text` | `content: string, variant?: "heading"\|"body"\|"caption"\|"code"` |
| `json_viewer` | `data: any, collapsed_depth?: number` |
| `image` | `src: string, alt?: string, width?: number, height?: number` |
| `metric` | `label: string, value: string\|number, change?: number, change_direction?: "up"\|"down", icon?: string` |
| `status_badge` | `label: string, status: "success"\|"warning"\|"error"\|"info"\|"neutral"` |

**Input components:**

| Type | Props |
|------|-------|
| `form` | `fields: [{key, type, label, required?, default?, options?, placeholder?}], submit_label?: string` |
| `button_group` | `buttons: [{key, label, variant?, icon?, disabled?}]` |
| `slider` | `key: string, label: string, min: number, max: number, step?: number, default?: number` |
| `file_upload` | `key: string, label: string, accept?: string[], max_size_bytes?: number` |
| `chat_input` | `placeholder?: string, submit_label?: string` |
| `date_picker` | `key: string, label: string, mode?: "date"\|"datetime"\|"range"` |

**Layout components:**

| Type | Props |
|------|-------|
| `page` | `title?: string, description?: string, max_width?: "sm"\|"md"\|"lg"\|"xl"\|"full"` |
| `grid` | `columns?: number, gap?: number` |
| `tabs` | `tabs: [{key, label, icon?}], default_tab?: string` |
| `sidebar` | `position?: "left"\|"right", width?: number, collapsible?: boolean` |
| `stack` | `direction?: "vertical"\|"horizontal", gap?: number, align?: string` |
| `columns` | `widths?: string[]` (e.g. `["1fr", "2fr"]`) |
| `divider` | `label?: string` |
| `modal` | `title?: string, size?: "sm"\|"md"\|"lg"` |

Layout components use `children: [descriptor, ...]` for composition, forming a render tree.

### Step Kind

Add `:render` to valid kinds in `Fizz.Integrations.StepDefinition` and `Fizz.Integrations.StepType`. All UI steps use `kind: :render`.

### Step Types

Category: `"Display"`, `"Input"`, `"Layout"`

All follow the standard executor pattern. Display steps resolve their config (using expressions for data binding) and return the descriptor as their output. Input steps return `{:wait_for_signal, signal_key, descriptor}` to pause for user interaction.

Example — Table executor:
```elixir
def execute(config, input, _ctx) do
  data = Map.get(config, "data", input)
  columns = Map.get(config, "columns") || auto_detect_columns(data)
  {:ok, %{"$ui" => "1.0", "type" => "table", "props" => %{"columns" => columns, "rows" => data}}}
end
```

Example — Form executor (pauses for input):
```elixir
def execute(config, _input, context) do
  signal_key = "ui_input:#{context["step_id"]}"
  descriptor = %{
    "$ui" => "1.0", "type" => "form",
    "props" => %{"fields" => config["fields"], "submit_label" => config["submit_label"] || "Submit"},
    "signal_key" => signal_key, "awaiting_input" => true
  }
  {:ok, {:wait_for_signal, signal_key, %{kind: "input", ui_spec: descriptor}, descriptor}}
end
```

### Client-Side Renderer

**Component tree:**
```
AppRenderer.vue (root)
  AppShell.vue (chrome)
    UIRenderer.vue (recursive descriptor interpreter)
      UITable.vue, UIChart.vue, UIMarkdown.vue, ...
      UIForm.vue, UIButtonGroup.vue, ...
      UIPage.vue, UIGrid.vue, UITabs.vue, ...
```

`UIRenderer.vue` is the core — a recursive component that resolves `descriptor.type` to the corresponding Vue component via a lazy component map (`defineAsyncComponent`). Layout components pass `children` recursively.

**State management:** `AppRenderer` maintains a reactive `Map<step_id, UIDescriptor>` updated as `step_completed` events arrive via PubSub. A `useUIComposer` composable assembles the render tree based on workflow topology.

**File locations:**
```
assets/vue/components/app/       -- all renderer components
assets/vue/composables/app/      -- useAppRenderer.ts, useUIComposer.ts
assets/vue/types/ui.ts           -- TypeScript types for descriptors
```

---

## Layer 4: App Shell & Deployment

### App Schema

```
apps
  id                          :binary_id PK
  project_id                  :binary_id FK
  workos_organization_id      :string
  workflow_definition_id      :binary_id FK
  workflow_definition_version_id :binary_id
  name                        :string
  slug                        :string        -- URL-safe identifier
  description                 :string
  icon                        :string
  status                      :string        -- "draft" | "published" | "archived"
  access_level                :string        -- "public" | "link" | "authenticated" | "org_only"
  session_mode                :string        -- "per_visit" | "per_user" | "shared"
  share_token                 :string        -- for link-based access
  settings                    :map
  published_at                :utc_datetime
  published_by_user_id        :string
  archived_at                 :utc_datetime
  timestamps()

  unique: [:workos_organization_id, :slug]
```

```
app_sessions
  id                     :binary_id PK
  app_id                 :binary_id FK -> apps
  workflow_run_id        :binary_id FK -> workflow_runs
  workos_organization_id :string
  status                 :string        -- "active" | "completed" | "expired"
  session_token          :string        -- unique
  user_id                :string        -- nullable for public apps
  user_metadata          :map
  expires_at             :utc_datetime
  timestamps()

  index: [:app_id, :user_id]
  unique: [:session_token]
```

### Access Levels

| Level | Who Can Access | Mechanism |
|-------|---------------|-----------|
| `:public` | Anyone with the URL | No auth |
| `:link` | Anyone with URL + share token | `?token=abc123` query param |
| `:authenticated` | Any logged-in WorkOS user | WorkOS session |
| `:org_only` | Members of the owning org | WorkOS org membership |

Enforced by `FizzWeb.AppAuth` on_mount hook.

### Session Modes

| Mode | Behavior | Best For |
|------|----------|----------|
| `:per_visit` | Fresh workflow run per page load | Calculators, one-shot forms, stateless tools |
| `:per_user` | One run per user, resumed on return | Multi-step wizards, persistent dashboards |
| `:shared` | Single run shared across all users | Team dashboards, shared data views |

### Routes

```elixir
# Public app viewer
scope "/a", FizzWeb do
  pipe_through [:browser, :maybe_fetch_current_scope]
  live_session :app_viewer, on_mount: [{FizzWeb.AppAuth, :resolve_app}] do
    live "/:app_slug", AppsLive.Show, :show
  end
end

# Embedded mode (minimal chrome, iframe-friendly)
scope "/embed", FizzWeb do
  pipe_through [:browser, :embedded_layout, :maybe_fetch_current_scope]
  live_session :embedded_app, on_mount: [{FizzWeb.AppAuth, :resolve_app}] do
    live "/:app_slug", AppsLive.Embed, :show
  end
end

# App management (authenticated)
# Inside existing :require_authenticated_user live_session
live "/projects/:project_id/apps", AppsLive.Index, :index
live "/projects/:project_id/apps/new", AppsLive.New, :new
live "/projects/:project_id/apps/:app_id/settings", AppsLive.Settings, :settings
```

### LiveView: `AppsLive.Show`

Mount flow:
1. Resolve app from slug (via on_mount)
2. Get or create session based on `session_mode`
3. Ensure workflow run exists (create if per_visit, find existing if per_user/shared)
4. Subscribe to `workflow_run:{run_id}` PubSub
5. Render `AppRenderer.vue` via LiveVue with `uiState` (step_id → descriptor map)

Handle `step_completed` events: if output has `$ui` field, merge into `uiState` assign → Vue reactively re-renders.

Handle `ui_signal` events from Vue: route through `Fizz.Workflows.signal_run` to deliver user input to the running workflow.

### Embedded Mode

`/embed/:app_slug` uses a minimal root layout (no nav, no header). Pipeline includes:
- Custom layout: `{FizzWeb.Layouts, :embedded}`
- `x-frame-options` removed, CSP `frame-ancestors *`

Usage:
```html
<iframe src="https://app.fizz.io/embed/my-app?token=abc123"
        width="100%" height="600" frameborder="0"></iframe>
```

Future: `<fizz-app>` web component wrapping the iframe with a nicer API.

### Context Module: `Fizz.Apps`

```elixir
# App CRUD
create_app(scope, attrs)
update_app(scope, app_id, attrs)
publish_app(scope, app_id)
archive_app(scope, app_id)
get_app(scope, app_id)
get_published_app_by_slug!(slug)
list_apps(scope)

# Sessions
create_session!(app, opts)
get_active_session(app_id, user_id)
get_shared_session(app_id)
link_session_to_run!(session, run)
verify_session_token(token)
expire_stale_sessions()

# Run lifecycle
create_and_start_run(app, session)
```

---

## New Files Summary

### Schemas & Context Modules
```
lib/fizz/app_state.ex
lib/fizz/app_state/kv_namespace.ex
lib/fizz/app_state/kv_entry.ex
lib/fizz/app_state/table.ex
lib/fizz/app_state/table_row.ex
lib/fizz/app_state/quota.ex
lib/fizz/app_state/lazy_store_access.ex
lib/fizz/app_state/events.ex
lib/fizz/app_state/row_validator.ex
lib/fizz/app_state/workers/kv_ttl_sweeper.ex
lib/fizz/workflows/interactions.ex
lib/fizz/workflows/interaction_request.ex
lib/fizz/workflows/chat_message.ex
lib/fizz/apps.ex
lib/fizz/apps/app.ex
lib/fizz/apps/app_session.ex
```

### Step Executors
```
lib/fizz/integrations/fizz/builtins/kv_get.ex
lib/fizz/integrations/fizz/builtins/kv_set.ex
lib/fizz/integrations/fizz/builtins/kv_delete.ex
lib/fizz/integrations/fizz/builtins/kv_list.ex
lib/fizz/integrations/fizz/builtins/kv_increment.ex
lib/fizz/integrations/fizz/builtins/kv_compare_and_swap.ex
lib/fizz/integrations/fizz/builtins/table_query.ex
lib/fizz/integrations/fizz/builtins/table_insert.ex
lib/fizz/integrations/fizz/builtins/table_update.ex
lib/fizz/integrations/fizz/builtins/table_delete.ex
lib/fizz/integrations/fizz/builtins/table_get_row.ex
lib/fizz/integrations/fizz/builtins/table_upsert.ex
lib/fizz/integrations/fizz/builtins/wait_for_input.ex
lib/fizz/integrations/fizz/builtins/wait_for_approval.ex
lib/fizz/integrations/fizz/builtins/send_to_client.ex
lib/fizz/integrations/fizz/builtins/request_input.ex
lib/fizz/integrations/fizz/builtins/ui/table.ex
lib/fizz/integrations/fizz/builtins/ui/chart.ex
lib/fizz/integrations/fizz/builtins/ui/markdown.ex
lib/fizz/integrations/fizz/builtins/ui/text.ex
lib/fizz/integrations/fizz/builtins/ui/json_viewer.ex
lib/fizz/integrations/fizz/builtins/ui/image.ex
lib/fizz/integrations/fizz/builtins/ui/metric.ex
lib/fizz/integrations/fizz/builtins/ui/status_badge.ex
lib/fizz/integrations/fizz/builtins/ui/form.ex
lib/fizz/integrations/fizz/builtins/ui/button_group.ex
lib/fizz/integrations/fizz/builtins/ui/slider.ex
lib/fizz/integrations/fizz/builtins/ui/file_upload.ex
lib/fizz/integrations/fizz/builtins/ui/chat_input.ex
lib/fizz/integrations/fizz/builtins/ui/date_picker.ex
lib/fizz/integrations/fizz/builtins/ui/page.ex
lib/fizz/integrations/fizz/builtins/ui/grid.ex
lib/fizz/integrations/fizz/builtins/ui/tabs.ex
lib/fizz/integrations/fizz/builtins/ui/sidebar.ex
lib/fizz/integrations/fizz/builtins/ui/stack.ex
lib/fizz/integrations/fizz/builtins/ui/columns.ex
lib/fizz/integrations/fizz/builtins/ui/divider.ex
```

### Channels & Web
```
lib/fizz_web/channels/app_state_channel.ex
lib/fizz_web/channels/workflow_run_channel.ex
lib/fizz_web/live/apps_live/show.ex
lib/fizz_web/live/apps_live/embed.ex
lib/fizz_web/live/apps_live/index.ex
lib/fizz_web/live/apps_live/settings.ex
lib/fizz_web/plugs/app_auth.ex
```

### Vue Components
```
assets/vue/components/app/AppRenderer.vue
assets/vue/components/app/AppShell.vue
assets/vue/components/app/UIRenderer.vue
assets/vue/components/app/UITable.vue
assets/vue/components/app/UIChart.vue
assets/vue/components/app/UIMarkdown.vue
assets/vue/components/app/UIText.vue
assets/vue/components/app/UIJsonViewer.vue
assets/vue/components/app/UIImage.vue
assets/vue/components/app/UIMetric.vue
assets/vue/components/app/UIStatusBadge.vue
assets/vue/components/app/UIForm.vue
assets/vue/components/app/UIButtonGroup.vue
assets/vue/components/app/UISlider.vue
assets/vue/components/app/UIFileUpload.vue
assets/vue/components/app/UIChatInput.vue
assets/vue/components/app/UIDatePicker.vue
assets/vue/components/app/UIPage.vue
assets/vue/components/app/UIGrid.vue
assets/vue/components/app/UITabs.vue
assets/vue/components/app/UISidebar.vue
assets/vue/components/app/UIStack.vue
assets/vue/components/app/UIColumns.vue
assets/vue/components/app/UIDivider.vue
assets/vue/components/app/UIModal.vue
assets/vue/composables/app/useAppRenderer.ts
assets/vue/composables/app/useUIComposer.ts
assets/vue/types/ui.ts
```

### Migrations
```
priv/repo/migrations/YYYYMMDDHHMMSS_create_app_state_tables.exs
priv/repo/migrations/YYYYMMDDHHMMSS_create_interaction_tables.exs
priv/repo/migrations/YYYYMMDDHHMMSS_create_apps_tables.exs
```

### Files to Modify
```
lib/fizz/integrations/step_definition.ex          -- add :render to valid kinds
lib/fizz/integrations/step_type.ex                -- add :render to step_kind type
lib/fizz/integrations/step_registry.ex            -- register all new executor modules
lib/fizz/workflows/step_executor.ex -- add execute_streaming/4 optional callback
lib/fizz/workflows/runner/worker.ex   -- signal_intent, handle_signal_intent, streaming dispatch
lib/fizz/workflows/runtime/context_builder.ex -- add store to base_context
lib/fizz/workflows/expressions.ex     -- add "store" binding
lib/fizz_web/router.ex                -- app routes
lib/fizz_web/user_socket.ex           -- register new channels
lib/fizz_web/components/layouts.ex    -- add embedded layout
```
