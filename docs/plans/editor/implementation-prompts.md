# Editor Implementation Prompts

Phased implementation prompts for the workflow editor. Each phase builds on the previous one and is designed to be executed as a single session.

**Specs:** `docs/spec/specs/editor.*.spec.md`
**Plans:** `docs/plans/editor/01-architecture.md` through `06-save-publish.md`

---

## Phase 1: DraftSession GenServer + Supervision

**Goal:** Build the core collaboration primitive — the DraftSession GenServer that holds authoritative draft state, applies operations, manages undo/redo, and persists periodically.

**Specs covered:** `editor.draft-session`, `editor.state-model` (partial), `editor.collaboration` (partial)

### Context

The backend data model is fully built. `Fizz.Workflows` has `save_draft/3` (full-document replacement to Postgres) and `edit_definition/2` (returns existing draft or clones published). `WorkflowDefinitionVersion` is the schema with embedded steps, connections, step_groups, viewport, and settings. There is no DraftSession, no GenServer for collaboration, and no operation model yet.

### What exists

- `Fizz.Workflows` context with `save_draft/3`, `edit_definition/2`, `publish_draft/2`
- `WorkflowDefinitionVersion` schema with full changeset validation (unique IDs, step type IDs, connection refs, acyclic graph, non-overlapping groups)
- `Fizz.Application` supervision tree (no DraftSession supervision yet)
- `Registry` pattern used by `Fizz.Workflows.Runner.Registry` for worker lookup
- `Phoenix.PubSub` configured as `Fizz.PubSub`

### What to build

1. **`Fizz.Workflows.DraftSession`** — GenServer module at `lib/fizz/workflows/draft_session.ex`

   State struct:
   ```elixir
   defstruct [
     :version_id, :draft, :seq, :undo_stacks, :redo_stacks,
     :dirty?, :last_persisted_seq, :connected_users, :persist_timer_ref,
     :idle_timer_ref, :scope
   ]
   ```

   Public API:
   - `join(version_id, scope, user_id)` — starts GenServer via DynamicSupervisor if not running, adds user to connected_users, returns `{draft, seq, undo_state}`
   - `leave(version_id, user_id)` — removes user; if last user, starts 5-minute idle timer
   - `apply_operation(version_id, user_id, %{type: atom, params: map})` — applies operation, increments seq, pushes inverse onto user's undo stack, clears user's redo stack, sets dirty, broadcasts `{:draft_updated, seq, summary}` on PubSub topic `"draft:#{version_id}"`
   - `undo(version_id, user_id)` — pops from undo stack, applies inverse as operation; if conflicts, pops and broadcasts `{:undo_rejected, user_id, reason}`
   - `redo(version_id, user_id)` — pops from redo stack, applies forward op
   - `persist_now(version_id)` — immediate DB persist, broadcasts `{:draft_persisted, seq}`
   - `get_undo_state(version_id, user_id)` — returns `%{canUndo, canRedo, undoLabel, redoLabel}`

   Internal behavior:
   - `handle_info(:persist_tick, state)` — persist if dirty, reschedule 5s timer
   - `handle_info(:idle_timeout, state)` — persist if dirty, terminate
   - `terminate/2` — persist if dirty
   - Register via `{DraftSessionRegistry, version_id}` for unique lookup

2. **`Fizz.Workflows.DraftSession.Operation`** — operation dispatch module at `lib/fizz/workflows/draft_session/operation.ex`

   Implement `apply(draft, %{type: type, params: params})` that returns `{:ok, new_draft, %{type, params, label}}` or `{:error, reason}`.

   Start with these structural operations (each returns an inverse operation for undo):
   - `add_step` — generates UUID for step ID, adds to draft.steps; inverse is `remove_step`
   - `remove_step` — removes step + connections referencing it; inverse is `add_step` with full step data + restore connections
   - `update_step` — merges changes into step; inverse is `update_step` with old values
   - `move_step` / `move_steps` — updates position(s); inverse restores old positions
   - `add_connection` — validates no self-connection, no duplicate, adds to connections; inverse is `remove_connection`
   - `remove_connection` — removes; inverse is `add_connection` with full data
   - `add_group` / `update_group` / `remove_group` — group CRUD with inverses
   - `set_group_membership` — updates step_ids for a group; inverse restores old membership
   - `commit_drag_layout` — batch position update for steps and groups; inverse restores old positions
   - `duplicate_steps` — copies steps with new UUIDs, offset positions; inverse is remove all new IDs
   - `tidy_layout` — batch reposition; inverse restores old positions

   Validation within each operation:
   - Step/connection/group exists before update/remove
   - No self-connections (source != target)
   - No duplicate connections (same source_output → target_input pair)
   - UUID format check

3. **Supervision additions in `Fizz.Application`:**
   ```elixir
   {DynamicSupervisor, name: Fizz.Workflows.DraftSessionSupervisor, strategy: :one_for_one}
   {Registry, keys: :unique, name: Fizz.Workflows.DraftSessionRegistry}
   ```
   Add these before `FizzWeb.Endpoint` in the children list.

### Tests

Write tests at `test/fizz/workflows/draft_session_test.exs`:
- Starting a session loads draft from DB
- `apply_operation` for each operation type returns updated draft
- Undo reverses the last operation
- Redo re-applies after undo
- Undo conflict (e.g., undo add_step after step was deleted) pops stack and rejects
- New operation clears redo stack
- Periodic persist writes to DB when dirty
- Idle timeout shuts down after last user leaves
- Multiple users have independent undo stacks
- Operation rejection doesn't modify state or increment seq

### Boundaries

- Do NOT build the LiveView yet — that's Phase 2
- Do NOT build PubSub broadcasting from Worker (execution events) — that's Phase 4
- Do NOT build `DraftValidator` — that's Phase 5
- Keep operations focused on structural mutations. Presence/cursor/execution operations are handled elsewhere.

---

## Phase 2: WorkflowEditorLive + Router

**Goal:** Build the LiveView host that loads definitions, joins the DraftSession, relays commands from Vue to the DraftSession, handles PubSub broadcasts, and pushes updated state to Vue as props.

**Specs covered:** `editor.state-model` (remainder), `editor.collaboration` (presence + PubSub wiring)

### Context

Phase 1 delivered the DraftSession GenServer with operation application, undo/redo, and persistence. The Vue component tree is fully built — `WorkflowEditor.vue` emits `editor_command` events with `{type, payload}` via LiveVue. The composables expect props matching `WorkflowEditorProps` (see `assets/vue/types/workflowEditor.ts`). Currently there is no LiveView to receive these events.

### What exists

- `DraftSession` GenServer from Phase 1
- `FizzWeb.Presence` module (already in supervision tree)
- `Fizz.Integrations.StepRegistry` with `list_types/0` for step type catalog
- `Fizz.Workflows.edit_definition/2` to load/create draft
- `Fizz.Workflows.Expressions` module with `parse/1`, `validate/1`
- Vue `WorkflowEditor.vue` emitting `editor_command` with types defined in `WorkflowEditorCommandType`
- LiveVue integration — `useLiveVue()`, `useLiveEvent()`, `<.vue>` component
- Router at `lib/fizz_web/router.ex` with existing `:require_authenticated_user` live_session

### What to build

1. **Routes** — add to the existing `live_session :require_authenticated_user` block in `lib/fizz_web/router.ex`:
   ```elixir
   live "/projects/:project_id/workflows/:definition_id/edit", WorkflowEditorLive, :edit
   live "/projects/:project_id/workflows/:definition_id/edit/runs/:run_id", WorkflowEditorLive, :debug
   ```

2. **`FizzWeb.WorkflowEditorLive`** at `lib/fizz_web/live/workflow_editor_live.ex`

   Uses `LiveVue, :live_view` (not `FizzWeb, :live_view`).

   **`mount/3`:**
   - Extract `project_id`, `definition_id` from params
   - Build scope from `socket.assigns.current_scope` with project
   - Call `Workflows.get_definition(scope, definition_id)` to load definition
   - Call `Workflows.edit_definition(scope, definition_id)` to get/create draft
   - Call `Fizz.Integrations.StepRegistry.all()` and build `node_library_items` (summary list for sidebar: `%{type_id, name, description, icon, category, step_kind, node_role}`)
   - Call `DraftSession.join(draft.id, scope, current_user_id)` to get `{draft, seq, undo_state}`
   - Track presence on `"draft:#{draft.id}"` via `Presence.track/4`
   - Subscribe to PubSub topic `"draft:#{draft.id}"`
   - If `:debug` live_action, also subscribe to `"workflow_run:#{run_id}"` and load execution

   **Assigns** (these become Vue props via `<.vue>`):
   ```elixir
   %{
     definition: definition,        # WorkflowDefinition
     draft: draft,                  # WorkflowDefinitionVersion (the mutable snapshot)
     step_types: step_types,        # [Type.t()]
     node_library_items: items,     # [map()] summary for sidebar
     collab_seq: seq,               # integer from DraftSession
     presences: presences,          # from Presence.list
     editor_state: %{pinned_outputs: %{}, disabled_steps: [], step_locks: %{}},
     execution: nil,                # WorkflowRun or nil
     step_executions: [],           # [map()]
     expression_previews: %{},      # %{field_key => result}
     undo_state: undo_state,        # %{canUndo, canRedo, undoLabel, redoLabel}
     credential_options: [],
     debug_execution_id: nil,       # or run_id for debug mode
     current_user_id: user_id
   }
   ```

   **`render/1`:**
   Build a `workflow` map from assigns that matches `WorkflowEditorProps.workflow` shape (the POC `Workflow` type). The Vue side expects `props.workflow` with nested `draft`. Construct this as:
   ```elixir
   workflow = %{
     id: assigns.definition.id,
     project_id: assigns.definition.project_id,
     name: assigns.definition.name,
     description: assigns.definition.description,
     status: if(assigns.definition.archived_at, do: "archived", else: "draft"),
     updated_at: assigns.definition.updated_at,
     draft: encode_draft(assigns.draft),
     project: %{name: assigns.project_name}
   }
   ```
   Then render:
   ```heex
   <Layouts.app flash={@flash} current_scope={@current_scope}>
     <.vue
       v-component="WorkflowEditor"
       v-socket={@socket}
       workflow={workflow}
       stepTypes={@step_types}
       nodeLibraryItems={@node_library_items}
       execution={@execution}
       stepExecutions={@step_executions}
       editorState={@editor_state}
       undoState={@undo_state}
       presences={@presences}
       currentUserId={@current_user_id}
       collabSeq={@collab_seq}
       expressionPreviews={@expression_previews}
       credentialOptions={@credential_options}
       debugExecutionId={@debug_execution_id}
     />
   </Layouts.app>
   ```

   **`handle_event("editor_command", %{"type" => type, "payload" => payload}, socket)`:**
   Dispatch based on type:

   | Type | Handler |
   |------|---------|
   | Structural ops (`add_step`, `remove_step`, `update_step`, `move_step`, `move_steps`, `add_connection`, `remove_connection`, `add_group`, `update_group`, `remove_group`, `set_group_membership`, `commit_drag_layout`, `duplicate_steps`, `tidy_layout`) | `DraftSession.apply_operation(version_id, user_id, %{type: type, params: payload})` |
   | `undo` | `DraftSession.undo(version_id, user_id)` |
   | `redo` | `DraftSession.redo(version_id, user_id)` |
   | `mouse_move` | `Presence.update(self(), "draft:#{version_id}", user_id, fn meta -> Map.merge(meta, cursor_data) end)` |
   | `selection_changed` | `Presence.update(...)` with selected_steps |
   | `preview_expression` | Debounce and call `Expressions.preview/2` (build in Phase 3) |
   | `save_workflow` | `DraftSession.persist_now(version_id)` |
   | `publish_workflow` | Handle in Phase 5 |
   | `run_test`, `run_node`, `cancel_execution` | Handle in Phase 4 |
   | `pin_output`, `unpin_output`, `disable_step`, `enable_step` | Update `editor_state` assign locally |

   **`handle_info` callbacks:**
   - `{:draft_updated, seq, summary}` — reload draft from DraftSession (or accept pushed draft), update `collab_seq` and `draft` assigns, push undo_state
   - `{:draft_persisted, seq}` — update `draft.updated_at` for "Last saved" display
   - `{:operation_rejected, user_id, reason}` — if user_id matches, push_event `"workflow:operation_rejected"` with reason
   - `{:undo_rejected, user_id, reason}` — push_event `"workflow:undo_conflict"`
   - Presence diff handlers for `presences` assign

3. **LiveVue Encoder** — implement `LiveVue.Encoder` for `WorkflowDefinitionVersion`, `WorkflowDefinition`, `Step`, `Connection`, `StepGroup`, and any other structs pushed as props. Strip Ecto metadata, convert atoms to strings where needed. Alternatively, build plain maps in the LiveView before assigning.

4. **Presence throttle** — for `mouse_move` events, add a simple timestamp-based throttle (~60ms) in the `handle_event` to avoid flooding Presence updates.

### Encoding strategy

The Vue side expects the `Workflow` type from `assets/vue/types/workflow.ts`. The current POC type has `workflow.draft.steps`, `workflow.draft.connections`, etc. The LiveView must build this shape from assigns. Create a private `encode_draft/1` function that converts the `WorkflowDefinitionVersion` struct into a plain map matching the TypeScript `WorkflowDraft` interface.

Important: The POC `Workflow` type has fields like `status`, `current_version_tag` that don't exist on the backend `WorkflowDefinition`. Map them:
- `workflow.status` → derive from `definition.archived_at` (nil = "draft", present = "archived")
- `workflow.current_version_tag` → `"v#{draft.version}"`
- `workflow.draft` → encoded version with steps, connections, step_groups, viewport, settings

### Tests

Write tests at `test/fizz_web/live/workflow_editor_live_test.exs`:
- Mounting loads definition and draft, renders the Vue component
- Sending `editor_command` with `add_step` applies operation via DraftSession
- Undo/redo commands work through DraftSession
- Presence is tracked on mount
- Unauthenticated users are redirected

### Boundaries

- Expression preview is a stub (returns empty) — full implementation in Phase 3
- Execution commands are stubs — Phase 4
- Publish is a stub — Phase 5
- Don't modify any Vue component files yet — the Vue side already emits the right events

---

## Phase 3: Expression Preview + Credential Resolution

**Goal:** Wire up expression preview and credential search from the LiveView to the existing backend modules.

**Specs covered:** `editor.step-config` (expression preview, credential resolution)

### Context

`Fizz.Workflows.Expressions` already has `parse/1`, `validate/1`, and the full Solid rendering pipeline. It does NOT have a `preview/2` convenience function. The LiveView from Phase 2 stubs `preview_expression`. Credential resolution exists in the steps system.

### What to build

1. **`Fizz.Workflows.Expressions.preview/2`** — add to `lib/fizz/workflows/expressions.ex`:
   ```elixir
   @spec preview(String.t(), map()) :: {:ok, term()} | {:error, String.t()}
   def preview(expression_string, context)
   ```
   This parses the expression via `parse/1`, then renders it against the provided context using the existing `render_template/2` or `resolve/2` path. Return `{:ok, rendered_result}` or `{:error, "Parse error: ..."}`.

2. **Expression preview handler in WorkflowEditorLive:**
   - On `preview_expression` command with `%{"step_id" => step_id, "field_key" => field_key, "expression" => expression}`:
   - Assemble context from the draft's upstream steps, pinned outputs in `editor_state`, and step executions
   - Call `Expressions.preview(expression, context)`
   - Update `expression_previews` assign: `Map.put(previews, field_key, result)`
   - Add debouncing: track a timer ref per field_key, cancel previous, schedule 300ms delay

3. **Context assembly helper** — private function `build_preview_context(step_id, draft, editor_state, step_executions)`:
   - Build `steps` namespace: for each upstream step of `step_id`, grab output from pinned_outputs (preferred), then step_executions (fallback), then empty map
   - Build `input` namespace: current step's resolved input data
   - Build `workflow` namespace: `%{"id" => definition.id, "name" => definition.name}`
   - Build `env` namespace: `%{}` (empty for now)

4. **Credential search handler:**
   - On a `search_credentials` command (or integrate with existing resolver pattern):
   - Call the credential resolver with scope and provider filter from the payload
   - Push results back via `push_event(socket, "credential_results", results)`

### Tests

- Expression preview with valid expression returns rendered result
- Expression preview with invalid expression returns error message
- Context assembly picks pinned outputs over execution outputs
- Debouncing: rapid preview requests only trigger one evaluation

### Boundaries

- Don't add expression syntax highlighting or autocomplete dropdown — those are Vue-side features that can be added independently
- Don't modify `Expressions` module beyond adding `preview/2`

---

## Phase 4: Execution Events + Test Runs

**Goal:** Add PubSub broadcasting from the Worker GenServer, wire test run triggering from the editor, and handle execution event streaming to the Vue canvas.

**Specs covered:** `editor.execution`

### Context

`Fizz.Workflows.Runner.Worker` is the fully-built execution engine. It does NOT broadcast PubSub events. `Fizz.Workflows.start_run/4` creates runs and starts workers. The Vue side has `ExecutionOverlay.vue`, `ExecutionTracePanel.vue`, and all execution composables — they just need real data via props.

### What to build

1. **PubSub broadcasting in Worker** — add a `broadcast/2` helper to `lib/fizz/workflows/runner/worker.ex`:
   ```elixir
   defp broadcast(run_id, event) do
     Phoenix.PubSub.broadcast(Fizz.PubSub, "workflow_run:#{run_id}", event)
   end
   ```

   Add broadcast calls at these points in the Worker's execution cycle:
   - After dispatching a runnable → `broadcast(run_id, {:step_started, %{run_id: ..., step_id: ..., attempt: ..., started_at: DateTime.utc_now()}})`
   - After a runnable completes → `broadcast(run_id, {:step_completed, %{run_id: ..., step_id: ..., attempt: ..., output: output, output_summary: truncate(output), duration_us: ..., completed_at: ...}})`
   - After a runnable fails → `broadcast(run_id, {:step_failed, %{run_id: ..., step_id: ..., attempt: ..., error: %{type: ..., message: ..., details: ...}, duration_us: ..., failed_at: ...}})`
   - On run status transitions → `broadcast(run_id, {:run_status_changed, %{run_id: ..., status: ..., timestamp: DateTime.utc_now()}})`

   For `output_summary`, truncate large outputs to ~1KB for canvas display. Full output is loaded on-demand.

   **Important:** Identify the exact callback/function in Worker where each event occurs. The Worker uses Runic's three-phase model. Read the full Worker module to find the right insertion points. Look for where `RunnableDispatched`, `RunnableCompleted`, and `RunnableFailed` events are processed.

2. **Test run handler in WorkflowEditorLive:**
   ```elixir
   def handle_event("editor_command", %{"type" => "run_test"}, socket) do
     # 1. Persist current draft
     DraftSession.persist_now(socket.assigns.draft.id)

     # 2. Cancel existing test run if any
     if socket.assigns.execution do
       Workflows.cancel_run(socket.assigns.current_scope, socket.assigns.execution.id)
       Phoenix.PubSub.unsubscribe(Fizz.PubSub, "workflow_run:#{socket.assigns.execution.id}")
     end

     # 3. Compile draft in-memory (without publishing)
     case Compiler.compile(socket.assigns.draft) do
       {:ok, _workflow, _hash} ->
         # 4. Start run tagged as editor_test
         {:ok, run} = Workflows.start_run(
           socket.assigns.current_scope,
           socket.assigns.draft,
           %{},
           triggered_by: %{"kind" => "editor_test", "user_id" => socket.assigns.current_user_id}
         )

         # 5. Subscribe to run events
         Phoenix.PubSub.subscribe(Fizz.PubSub, "workflow_run:#{run.id}")

         {:noreply, assign(socket, execution: run, step_executions: [], debug_execution_id: run.id)}

       {:error, errors} ->
         {:noreply, push_event(socket, "compilation_errors", %{errors: format_errors(errors)})}
     end
   end
   ```

3. **Execution event handlers in WorkflowEditorLive:**
   ```elixir
   def handle_info({:step_started, payload}, socket), do: ...
   def handle_info({:step_completed, payload}, socket), do: ...
   def handle_info({:step_failed, payload}, socket), do: ...
   def handle_info({:run_status_changed, %{status: status} = payload}, socket), do: ...
   ```
   Each handler updates the `step_executions` list and `execution` assign. On terminal status (completed/failed/cancelled), unsubscribe from the run topic.

4. **Cancel execution handler:**
   ```elixir
   def handle_event("editor_command", %{"type" => "cancel_execution"}, socket) do
     if socket.assigns.execution do
       Workflows.cancel_run(socket.assigns.current_scope, socket.assigns.execution.id)
     end
     {:noreply, socket}
   end
   ```

5. **On-demand I/O loading:**
   Handle `load_step_io` command — query the Worker's SQLite store for full input/output data for a specific step, push via `push_event(socket, "step_io_loaded", data)`.

6. **Debug mode** — in `mount/3`, when `live_action == :debug`:
   - Load the run via `Workflows.get_run(scope, run_id)`
   - Load step executions from the run's checkpoint store
   - Subscribe to `"workflow_run:#{run_id}"`
   - Set `execution` and `step_executions` assigns

### Tests

- Test run persists draft before compiling
- Test run starts a workflow run tagged with `editor_test`
- Step events update `step_executions` assign
- Terminal status triggers unsubscribe
- Cancel execution stops the run
- Compilation errors are pushed to client

### Boundaries

- Don't implement `run_node` (single step execution) yet — it requires additional infrastructure. Stub it.
- Don't add fan-out event broadcasting yet unless it's straightforward from the Worker's existing fan-out handling
- Keep the Worker changes minimal — only add broadcast calls, don't restructure

---

## Phase 5: Validation + Publish Pipeline

**Goal:** Build the DraftValidator module for structured publish-time validation, wire the publish flow through DraftSession, and update the publish modal contract.

**Specs covered:** `editor.validation`, `editor.version-lifecycle`

### Context

`WorkflowDefinitionVersion.changeset/3` already has all Tier 2 validations (unique IDs, step type IDs, connection refs, group refs, non-overlapping groups, acyclic graph) and publish-time validations (`validate_step_configs`, `validate_has_entry_step`, `validate_expression_integrity`, `validate_credential_accessibility`). But these return Ecto changeset errors, not the structured `%{step_id, field, message, severity, code}` format the Vue frontend needs.

### What to build

1. **`Fizz.Workflows.DraftValidator`** at `lib/fizz/workflows/draft_validator.ex`:

   ```elixir
   defmodule Fizz.Workflows.DraftValidator do
     defmodule ValidationError do
       defstruct [:step_id, :field, :message, :severity, :code]
       @type t :: %__MODULE__{
         step_id: String.t() | nil,
         field: String.t() | nil,
         message: String.t(),
         severity: :error | :warning,
         code: atom()
       }
     end

     @spec validate_for_publish(WorkflowDefinitionVersion.t(), Scope.t()) ::
       :ok | {:error, [ValidationError.t()]}
   end
   ```

   Implement these checks, returning structured errors:
   - `validate_has_entry_step` → code `:missing_entry_step`, step_id nil (global)
   - `validate_step_configs` → code `:invalid_step_config`, step_id set, field set if available
   - `validate_expression_integrity` → code `:invalid_expression`, step_id set, field set
   - `validate_credential_accessibility` → code `:inaccessible_credential`, step_id set, field set
   - `validate_trigger_roots` → code `:trigger_not_root`, step_id set (trigger steps with incoming connections)
   - `validate_acyclic` → code `:cycle_detected`, step_id nil
   - `validate_required_fields` → code `:missing_required_field`, step_id set, field set — check each step's config against its type's `config_schema.required`

   Reuse logic from `WorkflowDefinitionVersion` where possible — extract shared validation helpers.

2. **Publish handler in WorkflowEditorLive:**
   ```elixir
   def handle_event("editor_command", %{"type" => "publish_workflow"}, socket) do
     version_id = socket.assigns.draft.id
     scope = socket.assigns.current_scope

     # 1. Persist first
     DraftSession.persist_now(version_id)

     # 2. Reload draft from DB (DraftSession may have mutated)
     {:ok, draft} = Workflows.fetch_version(scope, version_id)

     # 3. Validate
     case DraftValidator.validate_for_publish(draft, scope) do
       :ok ->
         # 4. Publish
         case Workflows.publish_draft(scope, version_id) do
           {:ok, published} ->
             push_event(socket, "workflow:publish_result", %{success: true})
             # Redirect or update assigns
           {:error, reason} ->
             push_event(socket, "workflow:publish_result", %{success: false, error: format(reason)})
         end

       {:error, errors} ->
         push_event(socket, "workflow:publish_result", %{
           success: false,
           validation_errors: Enum.map(errors, &Map.from_struct/1)
         })
     end
   end
   ```

3. **Pre-publish validation** — add a `validate_draft` command handler that runs `DraftValidator.validate_for_publish/2` and pushes results to Vue without attempting to publish. The publish modal can call this on open to show the validation checklist.

4. **Trigger impact computation** — add a helper to compute what trigger registrations will change:
   ```elixir
   def compute_trigger_impact(draft, scope) do
     case Compiler.compile(draft) do
       {:ok, _workflow, _hash} ->
         # Compare draft's trigger steps against current active registrations
         ...
       {:error, _} -> nil
     end
   end
   ```

5. **Canvas validation error display** — add a `validation_errors` assign (map of step_id to error list) that the LiveView pushes after validation runs. The Vue side's `useWorkflowNodes` already has infrastructure for merging extra data into node data.

### Implement `LiveVue.Encoder` for `ValidationError`

Derive or implement the encoder so validation errors can be pushed as props.

### Tests

- `DraftValidator.validate_for_publish/2` catches missing required fields
- `DraftValidator.validate_for_publish/2` catches invalid expressions
- `DraftValidator.validate_for_publish/2` catches cycle
- `DraftValidator.validate_for_publish/2` returns `:ok` for valid draft
- Publish handler persists before validating
- Publish handler blocks on validation errors
- Successful publish transitions version to `:published`

### Boundaries

- Don't modify the existing `WorkflowDefinitionVersion` changeset validations — `DraftValidator` is an additional layer that produces structured errors, not a replacement
- Don't implement version diff view or rollback — those are future features

---

## Phase 6: TypeScript Type Alignment + Vue Data Path Updates

**Goal:** Update the Vue TypeScript types and composable data paths to match the real backend model now that the LiveView is pushing real data.

**Specs covered:** `editor.canvas` (data path alignment), `editor.step-config` (type alignment)

### Context

The POC Vue types in `assets/vue/types/workflow.ts` have mismatches with the backend model (documented in `01-architecture.md`). The composables access `props.workflow.draft.*` for data. With the LiveView now pushing real data, the types and paths need alignment.

### What to change

1. **`assets/vue/types/workflow.ts`** — update existing interfaces:
   - `Workflow` type: remove `public`, `user_id`, `current_version_tag`; add `project_id`, `created_by_user_id`, `archived_at`; change `status` to derive from `archived_at`
   - `WorkflowDraft` → should map to `WorkflowDefinitionVersion` shape with `version: number` (integer, not string tag), `status: 'draft' | 'published' | 'archived'`, embedded `steps`, `connections`, `step_groups`, `viewport`, `settings`
   - Remove separate `triggers` array — triggers are steps with `step_kind === 'trigger'`
   - `NodeGroup` (StepGroup): remove `output_step_id`
   - `Execution` → `WorkflowRun` shape: remove `execution_type`

2. **Data path updates in composables:**
   - Verify `useWorkflowNodes` reads from `props.workflow.draft.steps` (or adjust if the LiveView pushes a different shape)
   - Verify `useWorkflowEdges` reads from `props.workflow.draft.connections`
   - Update `useGrouping` to not reference `output_step_id`
   - Update `PublishModal.vue` to remove `version_tag` and `changelog` inputs; show validation results and trigger impact from props instead

3. **`GroupNode.vue`** — remove any reference to `output_step_id`

4. **`PublishModal.vue`** — redesign to show:
   - "Publishing as Version N" (auto-increment, no user input)
   - Validation checklist (from `validation_errors` prop or live event)
   - Trigger impact summary
   - Execution hash change indicator
   - Remove version_tag input and changelog textarea

### Approach

This phase is primarily about type edits and data path fixes. Do NOT restructure the Vue component architecture. Make the minimum changes needed to align types with the backend model. If a composable reads `props.workflow.draft.steps` and the LiveView sends `workflow.draft.steps`, no change is needed. Only fix actual mismatches.

### Tests

- Verify the editor mounts and renders with real backend data (integration test via `Phoenix.LiveViewTest`)
- Verify step nodes render with correct data from the draft
- Verify publish modal displays validation results

### Boundaries

- Don't add new Vue features (syntax highlighting, autocomplete) — those are independent enhancements
- Don't restructure composables — only fix data paths and types
- Don't change Pinia stores beyond making `undoStore` a pass-through for server state (it mostly already is)
