# 6. Save, Publish, Validation

## Context

The backend has `save_draft/3` (full-document replacement) and `publish_draft/2` (validates, compiles, freezes version). The POC has `PublishModal.vue` but uses incorrect contracts (version_tag, changelog). This document defines the production save/publish/validation pipeline.

---

## Draft Save Strategy

### Server-Side Periodic Persistence

Draft saves are managed by the `DraftSession` GenServer, not triggered per-keystroke from the client:

| Trigger | When | Notes |
|---------|------|-------|
| Periodic timer | Every 5 seconds if `dirty?` | DraftSession internal timer |
| Explicit save | User presses Cmd+S or clicks Save | `DraftSession.persist_now/1` |
| Before publish | Publish handler calls persist first | Ensures DB is current |
| Before shutdown | Idle timeout or SIGTERM | `terminate/2` callback |
| User disconnect | Last user leaves session | Before starting idle timer |

**No auto-save from the client.** Every user action sends an operation to the DraftSession (which applies it in-memory). The DraftSession decides when to flush to the database.

### Save Implementation

```elixir
# In DraftSession
defp persist_to_db(state) do
  attrs = %{
    steps: state.draft.steps,
    connections: state.draft.connections,
    step_groups: state.draft.step_groups,
    viewport: state.draft.viewport,
    settings: state.draft.settings
  }

  case Workflows.save_draft(state.scope, state.draft.id, attrs) do
    {:ok, updated_version} ->
      broadcast(state.version_id, {:draft_persisted, state.seq})
      %{state | dirty?: false, last_persisted_seq: state.seq, draft: updated_version}

    {:error, changeset} ->
      # Log error but don't crash — retry on next timer tick
      Logger.warning("Draft persist failed: #{inspect(changeset.errors)}")
      state
  end
end
```

### Save Status in UI

The editor toolbar shows save status:
- "All changes saved" (when `dirty? == false`)
- "Saving..." (during persist)
- "Unsaved changes" (when `dirty? == true`, operations applied but not yet persisted)
- "Last saved: 2 minutes ago" (from `draft.updated_at`)

The `collabSeq` and `last_persisted_seq` comparison drives this display. The LiveView pushes a `save_status` assign:

```elixir
%{
  status: :saved | :saving | :unsaved,
  last_saved_at: DateTime.t() | nil
}
```

---

## Validation Tiers

### Tier 1: Operation-Time (in DraftSession.apply_operation)

Fast, synchronous checks that prevent invalid state:

- Step exists for update/remove/move
- Connection source/target steps exist
- No self-connections
- No duplicate connection (same source_output → target_input pair)
- Step group refs point to existing steps
- UUID format validation

If validation fails, the operation is rejected and `{:operation_rejected, user_id, reason}` is broadcast. The Vue client shows a toast notification.

### Tier 2: Persist-Time (in Workflows.save_draft changeset)

Run by `WorkflowDefinitionVersion.save_changeset/2` when the DraftSession persists:

- Unique embed IDs (no duplicate step/connection/group IDs)
- Valid step type IDs (exist in registry)
- Connection step references exist in steps list
- Step group step_ids reference existing steps
- Non-overlapping step group membership (a step belongs to at most one group)
- **Acyclic graph validation** (critical — prevents DAG violations)

These validations run on the full document. If they fail on periodic persist, the DraftSession logs a warning but retains the in-memory state (it was valid at the operation level). This should not happen in practice if Tier 1 is correct.

### Tier 3: Publish-Time (in Workflows.publish_draft)

All Tier 2 checks plus:

| Validation | Description |
|-----------|-------------|
| `validate_has_entry_step` | At least one root step (or trigger step) |
| `validate_step_configs` | Each step's config passes `executor.validate_config/1` |
| `validate_expression_integrity` | All expressions parse via Solid, reference valid upstream steps, use only allowed filters |
| `validate_credential_accessibility` | Referenced credentials exist and are accessible in scope |
| `validate_trigger_roots` | Trigger steps have no incoming connections |
| Full compilation | `Compiler.compile/1` succeeds end-to-end |

**New backend module:**
```elixir
defmodule Fizz.Workflows.DraftValidator do
  @spec validate_for_publish(WorkflowDefinitionVersion.t(), Scope.t()) ::
    :ok | {:error, [ValidationError.t()]}

  defmodule ValidationError do
    @type t :: %__MODULE__{
      step_id: String.t() | nil,
      field: String.t() | nil,
      message: String.t(),
      severity: :error | :warning,
      code: atom()
    }
  end
end
```

Error codes enable the frontend to categorize and display errors appropriately:
- `:missing_required_field` → show on specific field
- `:invalid_expression` → show on expression field
- `:cycle_detected` → show on involved connections
- `:missing_entry_step` → show as global error
- `:invalid_step_config` → show on step with details
- `:inaccessible_credential` → show on credential field

---

## Compilation Pipeline Integration

### On Publish

```
User clicks "Publish"
  └─> Vue emits publish_workflow command
  └─> LiveView:
      1. DraftSession.persist_now(version_id)
      2. DraftValidator.validate_for_publish(draft, scope)
         ├─ {:error, errors} → push errors to Vue, abort
         └─ :ok → continue
      3. Workflows.publish_draft(scope, version_id)
         ├─ Compiler.compile(version)
         │   ├─ Normalizer.normalize → strip UI metadata → IR.Graph
         │   ├─ ExpressionCompiler.compile → validate/compile expressions
         │   ├─ Assembler.assemble → build Runic.Workflow
         │   └─ Hasher.hash → SHA-256 of execution payload
         ├─ Version status → :published
         ├─ compiled_hash stored
         └─ RegistrationManager.sync_on_publish → sync trigger registrations
      4. Push success to Vue with new version info
```

### UI-Only Changes Don't Affect Hash

Already implemented correctly. The Normalizer strips:
- `step.position`
- `step.notes`
- `step_groups` (entire array)
- `viewport`
- `settings`

Only these affect `compiled_hash`:
- Step IDs, type_ids, configs
- Connections (source/target/handles)
- Expression access plans

This means: moving steps, renaming groups, changing colors, adjusting viewport — none of these produce a new compiled_hash. The publish modal can show "No execution changes since last publish" when the hash matches.

---

## Version Management

### Lifecycle

```
create_definition(scope, attrs)
  → Definition + Version 1 (status: :draft)

save_draft(scope, version_1_id, attrs)
  → Version 1 updated (still :draft)

publish_draft(scope, version_1_id)
  → Version 1 (status: :published, compiled_hash set)

edit_definition(scope, definition_id)
  → Finds no draft; clones Version 1 → Version 2 (status: :draft)

publish_draft(scope, version_2_id)
  → Version 2 (status: :published)
  → Version 1 (status: :archived) [optional, or remains published]
```

**Key rules:**
- At most one draft per definition at any time
- `edit_definition/2` returns existing draft if one exists, otherwise clones latest published
- Published versions are immutable at the application layer
- Version numbers are auto-incrementing integers (not user-specified tags)

### POC Mismatch Resolution

| POC Concept | Backend Reality | Action |
|-------------|----------------|--------|
| `version_tag` (user-specified) | `version` (auto-integer) | Remove from publish modal |
| `changelog` | Not in schema | Remove from publish modal |
| `Workflow.status: 'active'` | No "active" status on definition | Use `archived_at` presence for archive/active distinction |
| Separate `WorkflowDraft` entity | Draft is a `WorkflowDefinitionVersion` with `status: :draft` | Flatten data access |

---

## Publish Modal UX

### Current (POC — `PublishModal.vue`)
- Input: version tag (string), changelog (textarea)
- Single "Publish" button

### Target
```
┌─── Publish Workflow ──────────────────────────────────┐
│                                                        │
│  Publishing as Version {N}                             │
│                                                        │
│  ┌─ Validation ──────────────────────────────────────┐ │
│  │ ✓ 12 steps, 15 connections                        │ │
│  │ ✓ All expressions valid                           │ │
│  │ ✓ All credentials accessible                      │ │
│  │ ✓ DAG is acyclic                                  │ │
│  │ ✓ 2 trigger registrations will be activated       │ │
│  │                                                    │ │
│  │ OR                                                 │ │
│  │                                                    │ │
│  │ ✗ Step "Fetch Orders": field "url" is required    │ │
│  │ ✗ Step "Send Email": expression references        │ │
│  │   unknown step "deleted_step"                     │ │
│  │ ⚠ Step "Notify Slack": credential expires in 3d   │ │
│  └────────────────────────────────────────────────────┘ │
│                                                        │
│  Execution hash: {unchanged | changed}                 │
│  (hash unchanged = no runtime behavior difference)     │
│                                                        │
│  Trigger impact:                                       │
│  • Webhook "order-created" — will be activated         │
│  • Schedule "daily-sync" — will fire at next cron      │
│                                                        │
│              [Cancel]  [Publish Version {N}]            │
│                                                        │
└────────────────────────────────────────────────────────┘
```

### Pre-Publish Validation

When the publish modal opens, the LiveView runs `DraftValidator.validate_for_publish/2` and pushes results to the Vue component. The "Publish" button is disabled if any `:error` severity items exist. Warnings (`:warning`) are shown but don't block.

### Trigger Impact Summary

On modal open, the LiveView computes:
```elixir
def compute_trigger_impact(draft, scope) do
  case Compiler.compile(draft) do
    {:ok, _workflow, _hash} ->
      manifest = Compiler.extract_trigger_manifest(draft)
      existing = Triggers.list_registrations(scope, definition_id: draft.workflow_definition_id, status: :active)

      %{
        activating: manifest -- existing_manifests,
        deactivating: existing_manifests -- manifest,
        unchanged: manifest & existing_manifests
      }
    {:error, _} ->
      nil  # compilation failed, can't compute impact
  end
end
```

---

## Validation Error Display

### On Canvas

Steps with validation errors get visual indicators:
- **Red badge** (number of errors) on the top-right corner of the node
- **Red border** on hover/selection if errors exist
- **Tooltip** on hover: first error message

Implementation: The LiveView pushes a `validation_errors` assign (map of `step_id => [errors]`). The `useWorkflowNodes` composable merges this into `StepNodeData`:

```typescript
{
  validationErrors: props.validationErrors?.[step.id] || [],
  hasErrors: (props.validationErrors?.[step.id]?.length || 0) > 0
}
```

### In Config Modal

When the config modal opens for a step with errors:
- Error banner at the top of the Config pane
- Per-field errors: red border + error message below the input
- Error fields are scrolled into view

### In Publish Modal

Structured error list (see mockup above). Clicking an error:
1. Closes the publish modal
2. Opens the config modal for the affected step
3. Scrolls to / highlights the affected field

---

## What Exists vs. What's New

**Exists:**
- `Workflows.save_draft/3` — full-document DB persistence
- `Workflows.publish_draft/2` — validates, compiles, publishes
- `WorkflowDefinitionVersion` changeset validations (Tier 2)
- Compilation pipeline (Normalizer, ExpressionCompiler, Assembler, Hasher)
- `PublishModal.vue` — modal component (needs UX update)
- Toolbar save button
- `compiled_hash` computation and storage

**New:**
- DraftSession periodic persistence (Tier 1 + batched Tier 2)
- `Fizz.Workflows.DraftValidator` module with `validate_for_publish/2`
- `ValidationError` struct with `step_id`, `field`, `code`, `severity`
- Publish modal redesign (remove version_tag/changelog, add validation display, trigger impact)
- Canvas validation error indicators
- Config modal per-field error display
- Save status indicator in toolbar
- Trigger impact computation for publish modal
- `load_step_io` event for on-demand I/O data

---

## Assumptions

1. **save_draft is idempotent:** Calling `save_draft/3` with the same data multiple times is safe (full-document replacement).
2. **Publish blocks on compilation:** The publish operation is synchronous from the user's perspective. Compilation should complete within a few seconds for typical workflows. For very large workflows (500+ steps), consider async compilation with a loading indicator.
3. **Single draft at a time:** `edit_definition/2` returns the existing draft or creates a new one. Two users can't create competing drafts.
4. **No version rollback in editor:** To revert, the user must create a new draft from an older published version. Direct rollback/revert is a separate feature.

## Follow-Up Work

- Version diff view (visual comparison between two versions on the canvas)
- Version rollback (create new draft from any historical version)
- Publish notes / changelog (add optional `notes` field to version schema)
- Draft auto-save conflict resolution (if the DraftSession crashes and restarts, reconcile with DB state)
- Publish approval workflow (require review before publishing)
- Canary / staged publishing (publish to subset of triggers first)
