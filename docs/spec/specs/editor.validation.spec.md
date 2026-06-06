# Editor Validation

Validation runs at three tiers with increasing strictness: operation-time (fast, per-operation), persist-time (full-document, on DB write), and publish-time (comprehensive, blocks publishing). Each tier catches progressively deeper issues.

~~~spec-meta
id: editor.validation
kind: policy
status: active
summary: Three-tier validation pipeline, error structure, and per-tier validation rules.
surface:
  - lib/fizz/workflows/draft_session.ex
  - lib/fizz/workflows/draft_session/operation.ex
  - lib/fizz/workflows/workflow_definition_version.ex
  - lib/fizz/workflows/draft_validator.ex
~~~

## Requirements

~~~spec-requirements
- id: editor.validation.req_tier1_operation_time
  statement: "Tier 1 (operation-time) validation runs synchronously in `DraftSession.apply_operation` and rejects operations that would create invalid state: referencing nonexistent steps, self-connections, duplicate connections, invalid step group references, and malformed UUIDs."
  priority: must
  stability: stable

- id: editor.validation.req_tier1_no_state_change
  statement: A rejected Tier 1 operation does not modify the draft, increment seq, or affect undo stacks.
  priority: must
  stability: stable

- id: editor.validation.req_tier2_persist_time
  statement: "Tier 2 (persist-time) validation runs in the `WorkflowDefinitionVersion` changeset during `save_draft` and checks: unique embed IDs, valid step type IDs in registry, connection step references exist, step group membership references exist, non-overlapping step group membership, and acyclic graph."
  priority: must
  stability: stable

- id: editor.validation.req_tier2_no_crash
  statement: If Tier 2 validation fails during periodic persistence, the DraftSession logs a warning and retains the in-memory state. It does not crash.
  priority: must
  stability: stable

- id: editor.validation.req_tier3_publish_time
  statement: "Tier 3 (publish-time) validation includes all Tier 2 checks plus: at least one root/trigger step exists, each step config passes `executor.validate_config/1`, all expressions parse and reference valid upstream steps with allowed filters, referenced credentials are accessible in scope, trigger steps have no incoming connections, and full compilation via `Compiler.compile/1` succeeds."
  priority: must
  stability: stable

- id: editor.validation.req_tier3_blocks_publish
  statement: Publish is blocked if any Tier 3 validation error with severity `:error` exists. Warnings do not block.
  priority: must
  stability: stable

- id: editor.validation.req_error_structure
  statement: "Validation errors are structured as `%{step_id, field, message, severity, code}` where `step_id` and `field` are nullable (nil for global or step-level errors respectively), severity is `:error` or `:warning`, and `code` is an atom identifying the error type."
  priority: must
  stability: stable

- id: editor.validation.req_error_codes
  statement: "Error codes include at minimum: `:missing_required_field`, `:invalid_expression`, `:cycle_detected`, `:missing_entry_step`, `:invalid_step_config`, `:inaccessible_credential`."
  priority: must
  stability: stable

- id: editor.validation.req_canvas_error_display
  statement: Steps with validation errors display a red badge with error count on the canvas node. Hovering shows the first error message as a tooltip.
  priority: should
  stability: stable

- id: editor.validation.req_config_modal_errors
  statement: In the config modal, field-level errors show a red border and error message below the input. Step-level errors appear in a collapsible section at the top of the Config pane.
  priority: should
  stability: stable
~~~

## Scenarios

~~~spec-scenarios
- id: editor.validation.scenario_tier1_rejects_self_connection
  given:
    - A draft with step S1
  when:
    - An `add_connection` operation is applied with source=S1, target=S1
  then:
    - The operation is rejected with an appropriate reason
    - Draft state, seq, and undo stacks are unchanged
  covers:
    - editor.validation.req_tier1_operation_time
    - editor.validation.req_tier1_no_state_change

- id: editor.validation.scenario_tier3_blocks_publish
  given:
    - A draft where step "Fetch Orders" has a required `url` field that is empty
  when:
    - The user opens the publish modal
  then:
    - `DraftValidator.validate_for_publish/2` returns an error with code `:missing_required_field`, step_id pointing to "Fetch Orders", and field `url`
    - The publish button is disabled
  covers:
    - editor.validation.req_tier3_publish_time
    - editor.validation.req_tier3_blocks_publish
    - editor.validation.req_error_structure
~~~

## Verification

~~~spec-verification
- kind: source_file
  target: lib/fizz/workflows/draft_session/operation.ex
  covers:
    - editor.validation.req_tier1_operation_time
    - editor.validation.req_tier1_no_state_change

- kind: source_file
  target: lib/fizz/workflows/workflow_definition_version.ex
  covers:
    - editor.validation.req_tier2_persist_time

- kind: source_file
  target: lib/fizz/workflows/draft_validator.ex
  covers:
    - editor.validation.req_tier3_publish_time
    - editor.validation.req_error_structure
    - editor.validation.req_error_codes
~~~
