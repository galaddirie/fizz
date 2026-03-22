# ISSUE-005: No Input UI for Manual Trigger — Cannot Provide Test Data

**Priority:** High
**Component:** Workflow Editor / Manual Trigger / Test Runs
**Status:** Open

## Summary

When running a test execution for a workflow with a manual trigger, there is no UI to provide input data. The manual trigger step supports an `input_schema` configuration, but the editor always starts test runs with empty input `%{}`. Users have no way to supply dummy/test data to exercise their workflow end-to-end.

## Current Behavior

The manual trigger executor (`lib/fizz/steps/executors/manual_input.ex`) supports:

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

1. **Pre-run modal** — When "Run Test" is clicked:
   - Identify the trigger step from the draft
   - If it's a manual trigger with an `input_schema`, show a modal with a JSON form or JSON editor pre-populated with the schema's default values
   - Allow the user to fill in test data
   - On "Run", pass the input to `start_editor_test_run/2` → `Workflows.start_run/4`

2. **Schema-driven form** — Generate form fields from the JSON Schema `input_schema`:
   - String fields → text inputs
   - Number fields → number inputs
   - Boolean fields → toggles
   - Object/array → nested forms or a raw JSON editor as fallback

3. **Fallback raw JSON editor** — For complex schemas, allow the user to paste/edit raw JSON input

4. **For non-manual triggers** — Webhook triggers could show a sample payload editor; schedule triggers could use a "run now" button with no input needed.

## Relevant Files

- `lib/fizz/steps/executors/manual_input.ex` — Manual trigger executor with `input_schema` support
- `lib/fizz_web/live/workflows_live/editor.ex` — `start_editor_test_run/2` (line 582), `run_test/1` (line 561)
- `assets/vue/components/flow/step_config/` — Step config modal (could be extended for input form)
- `assets/vue/types/configSchema.ts` — Config schema types

## Steps to Reproduce

1. Create a workflow with a Manual Trigger step
2. Configure an `input_schema` on the trigger (e.g., `{"type": "object", "properties": {"name": {"type": "string"}}}`)
3. Add downstream steps that reference trigger output
4. Click "Run Test"
5. Execution starts with empty input — downstream steps fail or produce empty results
6. No opportunity to provide test data

## Expected Behavior

Clicking "Run Test" on a workflow with a manual trigger should prompt the user with a form (driven by the trigger's `input_schema`) to enter test input data before starting the execution.

## Acceptance Criteria

- [ ] "Run Test" detects the trigger type and shows an input form for manual triggers
- [ ] Input form is generated from the trigger's `input_schema` JSON Schema
- [ ] User can enter test data and submit to start the execution
- [ ] Input data is passed to `Workflows.start_run/4` as the trigger event
- [ ] Raw JSON editor is available as a fallback for complex schemas
- [ ] For triggers without `input_schema`, the run starts immediately with no prompt
