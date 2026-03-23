# ISSUE-001: Cannot Save Drafts — Needs Google Docs-Style Autosave

**Priority:** High
**Component:** Workflow Editor / DraftSession
**Status:** Resolved

## Summary

Users cannot save workflow drafts from the editor. Beyond fixing the immediate bug, the save model needs to be rethought for a collaborative editor — manual "Save" buttons are the wrong UX when multiple users are editing simultaneously. The editor should autosave continuously like Google Docs.

## Current Behavior

The `save_workflow` event in `editor.ex:115` calls `persist_draft/1`, which delegates to `DraftSession.persist_now/1`. The DraftSession GenServer also runs a background `persist_tick` every 5 seconds that should auto-save dirty state. Despite this, drafts are not being saved.

## Root Cause Investigation

Potential areas to investigate for the immediate save bug:

1. **DraftSession.persist_now/1** (`draft_session.ex`) — The GenServer `handle_call({:persist, :immediate}, ...)` handler may be failing silently. The `persist_draft/1` function in `editor.ex:467-474` only pushes an ack event on success but does not surface errors to the user beyond the `else` branch.

2. **Workflows.save_draft/3** — The underlying context function that writes to the database. The `WorkflowDefinitionVersion.save_changeset/2` may be rejecting changes due to validation errors on embedded schemas (steps, connections, step_groups, viewport, settings).

3. **Dirty flag not being set** — Operations applied via `apply_operation` set `dirty?: true`, but if the flag is not being set correctly, neither the auto-persist tick nor `persist_now` will actually write to the database.

4. **Race condition** — The `persist_tick` timer and explicit `persist_now` calls may conflict if they fire simultaneously, causing one to see `dirty?: false` after the other already persisted.

## Smarter Autosave for Collaborative Editing

The current model (manual "Save" button + 5s background tick) is inadequate for a collaborative editor. In a multi-user session, every user expects their changes to be saved automatically and visible to others immediately. The paradigm should shift from "user saves" to "system saves continuously."

### Design Goals (Google Docs model)

1. **Every operation is the save** — When a user applies an operation (add step, move step, edit config), the DraftSession GenServer already holds the updated state in memory. Persistence to the database should be a background concern, not a user action. The in-memory GenServer state *is* the authoritative draft; the database is a durability layer.

2. **Debounced persistence, not periodic** — Instead of a fixed 5s tick, persist after a short debounce (e.g., 1-2s) following the last operation. This means rapid edits batch naturally, but idle drafts don't generate unnecessary writes. Reset the debounce timer on each new operation.

3. **Save status indicator, not a save button** — Replace the "Save" button with a status indicator:
   - "All changes saved" (green) — GenServer state matches last persisted state
   - "Saving..." (subtle) — Debounce timer is active, persistence pending
   - "Offline / Error" (warning) — Persistence failed, will retry

   Users should never need to think about saving.

4. **Persist on critical moments** — Force immediate persistence (bypass debounce) on:
   - User navigating away / closing tab (`beforeunload` + LiveView `terminate/2`)
   - Before "Run Test" (already done in `run_test/1`)
   - Before "Publish" (already done in `publish_workflow/1`)
   - Last user disconnecting from the session

5. **Retry with backoff on failure** — If `Workflows.save_draft/3` fails, retry with exponential backoff rather than silently dropping the save. Surface persistent failures to all connected users.

6. **No data loss on crash** — If the GenServer crashes, the DynamicSupervisor restarts it. On restart, it loads the last persisted state from the database. Any operations applied between the last persist and the crash are lost. To minimize this window, persist more aggressively (shorter debounce) or consider a WAL-style operation log.

### User Join Should Not Reset Other Users' State (formerly ISSUE-002)

Currently, when a new user joins the editing session, all other connected users have their editor state reset. This happens because:

- `handle_info({:draft_updated, ...})` in `editor.ex:168` calls `refresh_draft_state/1` on every draft update broadcast
- `refresh_draft_state/1` (`editor.ex:802`) calls `DraftSession.join/3`, which returns the full GenServer state and re-assigns it to the socket via `assign_draft_state/4`
- This replaces the entire draft assign, disrupting viewport, selection, and any in-progress local UI state

This is a symptom of the broken save model, not a separate issue. If the GenServer state is always authoritative and operations sync incrementally (not via full-state replacement), then a new user joining simply gets the current state — same as everyone else. Existing users should receive **incremental operation broadcasts**, not full state refreshes triggered by join events.

Fixing this requires:

- **Separate "join" from "sync"** — `DraftSession.join/3` should add the user to connected_users without broadcasting a `:draft_updated` to existing users
- **Incremental updates** — When an operation is applied, broadcast the operation itself (not the full state) so clients can apply it locally
- **Full refresh only on reconnect** — A user who reconnects after a disconnect should get a full state refresh; users who were continuously connected should not

### Implementation Notes

- The DraftSession GenServer is the right place for all persistence logic — it already serializes all operations
- The `persist_tick` interval can be replaced with a debounce: schedule a `persist_after_debounce` timer on each `apply_operation`, canceling any existing timer
- The `dirty?` flag already tracks whether persistence is needed
- The save button in the Vue toolbar should become a read-only status indicator driven by a `save_status` assign (`:saved`, `:saving`, `:error`)
- `refresh_draft_state/1` should only be called on reconnect or error recovery, not on peer join/operation events

## Relevant Files

- `lib/fizz_web/live/workflows_live/editor.ex` — `persist_draft/1` (line 467), `save_workflow` event (line 115), `refresh_draft_state/1` (line 802), `handle_info({:draft_updated, ...})` (line 168)
- `lib/fizz/workflows/draft_session.ex` — GenServer managing draft state, `persist_tick`, dirty flag, `handle_call({:join, ...})` (line 148)
- `lib/fizz/workflows.ex` — `save_draft/3` context function

## Steps to Reproduce

1. Open a workflow in the editor
2. Add or modify a step
3. Click "Save" in the toolbar
4. Refresh the page
5. Changes are lost

## Expected Behavior

Changes should be automatically and continuously saved. Users should see a "All changes saved" indicator and never need to manually save. On page refresh, all changes should be intact.

## Resolution

- Replaced the periodic `persist_tick` model with debounced persistence and retry/backoff inside `DraftSession`
- Added shared save-state broadcasting so every connected editor sees `saved` / `saving` / `error`
- Swapped the manual save button for save-status UI and kept explicit persist points for unload, run test, publish, and last-user disconnect
- Changed collaborative sync to apply incremental operations locally and only fall back to full snapshot refresh on recovery paths

## Acceptance Criteria

- [x] Fix the immediate save bug — `persist_now` must successfully write to the database
- [x] Replace fixed 5s `persist_tick` with debounced persistence (1-2s after last operation)
- [x] Remove the manual "Save" button; replace with a save status indicator
- [x] Save status indicator shows "All changes saved" / "Saving..." / "Error"
- [x] Force-persist on navigation away, run test, publish, and last user disconnect
- [x] Retry failed persistence with backoff; surface persistent failures to users
- [x] Save errors are surfaced to all connected users, not just the one who triggered the save
- [x] New user joining does not trigger full state refresh for existing users
- [x] Operations broadcast incrementally (not full state replacement)
- [x] Local UI state (viewport, scroll, selection) is preserved across peer updates
- [x] Full state refresh only on reconnect or error recovery
