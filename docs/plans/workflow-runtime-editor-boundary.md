# Workflow Runtime Editor Boundary Plan

Status date: 2026-05-28

## Goal

Reduce LiveView/editor coupling to workflow internals by adding facade functions and moving web serialization out of core workflow modules.

## Non-Goals

- Do not redesign the workflow editor.
- Do not change draft collaboration semantics.
- Do not change the persisted workflow definition schema unless a facade gap requires it.
- Do not mix UI redesign with boundary cleanup.

## Plan

### Phase 1 - Alias Audit

List current `WorkflowEditorLive` and related web aliases into workflow internals.

Classify each usage as:

- public context call that can stay
- draft-session operation that needs a facade
- payload/encoding concern that belongs in `FizzWeb`
- genuine internal dependency that needs a narrow adapter

Exit criteria: web-to-domain coupling is visible before edits.

### Phase 2 - Draft Facade

Add `Fizz.Workflows` facade functions for normal editor operations:

- join draft session
- leave draft session
- apply operation
- undo
- redo
- persist now
- read undo state
- read editor/draft snapshot

Exit criteria: LiveViews no longer need direct DraftSession calls for normal workflow editing.

### Phase 3 - Web Payload Ownership

Move LiveVue and LiveView-specific encoding into web-owned modules, such as:

- `FizzWeb.WorkflowsLive.Payload`
- `FizzWeb.WorkflowEditorPayload`

Core workflow structs should remain domain structs. Web modules should shape them into props/events.

Exit criteria: core workflow modules do not carry UI serialization responsibilities.

### Phase 4 - LiveView Migration

Update editor LiveViews to call:

- `Fizz.Workflows` for domain operations
- web payload modules for prop/event shaping
- Phoenix Presence directly only for ephemeral collaboration state

Exit criteria: normal editor workflows import the context facade and web payload helpers, not draft-session internals.

### Phase 5 - Fixture Cleanup

Consolidate duplicated workflow/editor fixtures where duplication hides behavior.

Exit criteria: editor tests use fixture helpers that match domain contracts instead of hand-built incompatible maps.

## Acceptance Criteria

- `WorkflowEditorLive` does not import `DraftSession` internals for normal operations.
- Core workflow structs do not expose LiveVue-specific encoding decisions.
- Existing editor behavior is unchanged.
- Draft collaboration tests and LiveView tests pass.

## Test Commands

```bash
mix test test/fizz/workflows/draft_session_test.exs
mix test test/fizz/workflows/draft_validator_test.exs
mix test test/fizz_web/live/workflow_editor_live_test.exs
mix precommit
```

## Rollout / Rollback

Can roll out after internal boundary direction is accepted. Rollback is code revert because this should be facade and call-site movement only.

## Dependencies

- Stable `Fizz.Workflows` facade direction.
- Agreement on payload module ownership under `FizzWeb`.

