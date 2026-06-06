# ISSUE-005: No Input UI for Manual Trigger — Cannot Provide Test Data

**Priority:** High
**Component:** Workflow Editor / Manual Trigger / Test Runs
**Status:** Open

## Summary

When running a test execution for a workflow with a manual trigger, there is no UI to provide input data. The manual trigger step supports an `input_schema` configuration, but the editor always starts test runs with empty input `%{}`. Users have no way to supply dummy/test data to exercise their workflow end-to-end.

## Current Behavior

The manual trigger executor (`lib/fizz/integrations/fizz/builtins/manual_input.ex`) supports:

- `input_schema` config field — a JSON Schema defining the expected input shape
- `execute/2` — simply returns the input event data as output (pass-through)
- `normalize_event/2` — passes raw event data through unchanged

When a user clicks "Run Test", `start_editor_test_run/2` (`editor.ex:582-590`) calls:

```elixir
Workflows.start_run(scope, draft, %{}, triggered_by: %{"kind" => "editor_test", ...})
```

The third argument `%{}` is the trigger input — always empty. There is no modal, form, or UI component that:

1. Detects the trigger step type (manual vs webhook vs schedule)
2. Reads the trigger's `input_schema` configuration
3. Renders a form matching that schema
4. Collects user input and passes it to `start_run/4`

## Impact

- Workflows with manual triggers cannot be tested with realistic data
- Steps downstream of the trigger receive empty input, causing failures or meaningless test results
- Users cannot validate that their `input_schema` is correct before publishing
- The "Run Test" feature is effectively broken for manual-trigger workflows

## Proposed Solution

**Scope:** Manual triggers only. Other trigger types (webhook, schedule, etc.) will be addressed separately.

### Approach: Test Data in the Context Panel (n8n-style)

Instead of a pre-run modal that interrupts the execute flow, repurpose the **left-side context panel** (`StepConfigContextPane.vue`) when a manual trigger step is open. This panel is currently unused for trigger steps (they have no upstream input), making it the natural place for test data configuration.

#### How it works

1. **Context panel becomes a test data editor for manual triggers** — When the user opens a manual trigger step's config modal, the left panel (which normally shows "Input Data", "Trigger Data", "Upstream Steps") instead renders a JSON editor for test input data.

2. **Test data is persisted on the step** — The entered test data is saved as part of the step's configuration (e.g. `step.config["test_data"]`), so it survives page reloads and is always ready. This means:
   - No modal interruption when clicking "Run Test" or "Run to here"
   - Works for full workflow execution AND partial "run to here" execution
   - Supports fast iteration — edit data, run, see results, tweak, repeat
   - Works regardless of how many triggers/paths the workflow has (each trigger stores its own test data)

3. **Schema-aware defaults** — If the trigger has an `input_schema`, the editor can pre-populate with example values matching the schema. If no schema is configured, the editor starts with an empty `{}` that the user can fill in freely.

4. **Server reads test data at run time** — When `start_editor_test_run/2` fires, instead of hardcoding `%{}`, it reads the trigger step's `config["test_data"]` from the draft and passes it to `Workflows.start_run/4`.

#### UX flow

1. User adds a Manual Trigger step to the workflow
2. User opens the trigger step config (click or double-click)
3. Left panel shows "Test Data" with a JSON editor (instead of the usual input/context explorer)
4. User enters test data (e.g. `{"name": "Jane", "email": "jane@example.com"}`)
5. Data auto-saves to the step config (same as any other config field)
6. User clicks "Execute workflow"  or "Run to here" (node menu) — execution starts immediately using the saved test data
7. Results appear in the output panel — user tweaks test data and re-runs as needed

#### Why not a pre-run modal?

- **Interrupts flow** — A modal on every "Run Test" click adds friction, especially during fast iteration
- **Doesn't scale** — Workflows with multiple trigger paths (e.g. manual + webhook) would need the modal to ask "which trigger?" then show the right form
- **Disconnected from the step** — Test data logically belongs to the trigger node, not to a transient modal
- **No persistence** — Modal data is lost on page reload unless separately persisted anyway

### Non-goals (for this issue)

- Webhook trigger test payloads (separate issue)
- Schedule trigger "run now" behavior (separate issue)
- Schema-driven form generation (nice-to-have follow-up — raw JSON editor is sufficient for v1)

## Relevant Files

- `lib/fizz/integrations/fizz/builtins/manual_input.ex` — Manual trigger executor with `input_schema` and `test_data` config
- `lib/fizz_web/live/workflows_live/editor.ex` — `start_editor_test_run/2` — needs to read `test_data` from the trigger step instead of hardcoding `%{}`
- `assets/vue/components/flow/step_config/StepConfigContextPane.vue` — Left panel, needs trigger-specific test data editor mode
- `assets/vue/components/flow/step_config/useInputData.ts` — Input state logic, knows whether current step is a trigger
- `assets/vue/components/flow/step_config/useStepConfig.ts` — Step config state management
- `assets/vue/types/configSchema.ts` — Config schema types

## Steps to Reproduce

1. Create a workflow with a Manual Trigger step
2. Configure an `input_schema` on the trigger (e.g., `{"type": "object", "properties": {"name": {"type": "string"}}}`)
3. Add downstream steps that reference trigger output
4. Click "Run Test"
5. Execution starts with empty input — downstream steps fail or produce empty results
6. No opportunity to provide test data

## Expected Behavior

Opening a manual trigger step shows a test data JSON editor in the left context panel. Data entered here is persisted on the step and automatically used when running test executions — no interrupting modal, no lost data on reload.

## Acceptance Criteria

- [ ] Manual trigger steps show a "Test Data" JSON editor in the left context panel (replacing the usual input/context explorer)
- [ ] Test data is persisted as `step.config["test_data"]` and survives page reloads
- [ ] `start_editor_test_run/2` reads the trigger step's `test_data` config and passes it to `Workflows.start_run/4`
- [ ] If no test data is configured, execution starts with `%{}` (current behavior, no regression)
- [ ] Works for both "Run Test" (full workflow) and "Run to here" (partial execution)
- [ ] Non-manual triggers are unaffected (context panel shows normal input/context data)
