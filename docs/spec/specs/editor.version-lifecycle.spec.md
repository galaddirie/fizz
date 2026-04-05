# Editor Version Lifecycle

Workflow definitions follow a strict draft-publish-archive lifecycle. At most one draft exists per definition at any time. Publishing validates, compiles, freezes the version, and activates trigger registrations.

~~~spec-meta
id: editor.version_lifecycle
kind: workflow
status: active
summary: Draft/published/archived transitions, publish pipeline, compilation hash semantics, trigger impact.
surface:
  - lib/fizz/workflows.ex
  - lib/fizz/workflows/compiler.ex
  - lib/fizz/workflows/draft_validator.ex
~~~

## Requirements

~~~spec-requirements
- id: editor.version.req_single_draft
  statement: At most one draft version exists per workflow definition at any time. `edit_definition/2` returns the existing draft if one exists, otherwise clones the latest published version.
  priority: must
  stability: stable

- id: editor.version.req_version_auto_increment
  statement: Version numbers are auto-incrementing integers assigned by the system. They are not user-specified tags.
  priority: must
  stability: stable

- id: editor.version.req_published_immutable
  statement: Published versions are immutable at the application layer. No mutations are allowed to a version with status `:published`.
  priority: must
  stability: stable

- id: editor.version.req_publish_pipeline
  statement: "Publishing a draft executes this pipeline in order: (1) persist current draft state, (2) run `DraftValidator.validate_for_publish/2`, (3) if valid, call `Workflows.publish_draft/2` which compiles, sets status to `:published`, stores `compiled_hash`, and syncs trigger registrations."
  priority: must
  stability: stable

- id: editor.version.req_publish_blocks_on_errors
  statement: Publishing is blocked if `validate_for_publish/2` returns any error with severity `:error`. Warnings are displayed but do not block.
  priority: must
  stability: stable

- id: editor.version.req_hash_excludes_ui
  statement: "The `compiled_hash` is computed after the Normalizer strips UI metadata (step positions, notes, step_groups, viewport, settings). Only step IDs, type_ids, configs, connections, and expression access plans affect the hash."
  priority: must
  stability: stable

- id: editor.version.req_hash_unchanged_indicator
  statement: When the compiled_hash of the draft matches the previously published version's hash, the publish modal indicates "No execution changes since last publish."
  priority: should
  stability: stable

- id: editor.version.req_compilation_pipeline
  statement: "The compilation pipeline runs: Normalizer (strip UI metadata to IR.Graph) -> ExpressionCompiler (validate and compile expressions) -> Assembler (build Runic.Workflow) -> Hasher (SHA-256 of execution payload)."
  priority: must
  stability: stable

- id: editor.version.req_trigger_sync_on_publish
  statement: After successful publish, `RegistrationManager.sync_on_publish` is called to activate, deactivate, or update trigger registrations based on the compiled workflow.
  priority: must
  stability: stable

- id: editor.version.req_trigger_impact_preview
  statement: The publish modal displays a trigger impact summary showing which registrations will be activated, deactivated, or remain unchanged.
  priority: should
  stability: stable

- id: editor.version.req_save_status_display
  statement: "The editor toolbar displays save status derived from the DraftSession: \"All changes saved\" (not dirty), \"Saving...\" (persist in progress), \"Unsaved changes\" (dirty, pending persist), and \"Last saved: N ago\" (from `updated_at`)."
  priority: should
  stability: stable
~~~

## Scenarios

~~~spec-scenarios
- id: editor.version.scenario_edit_creates_draft
  given:
    - A definition with Version 1 (published) and no existing draft
  when:
    - A user calls `edit_definition(scope, definition_id)`
  then:
    - Version 2 is created with status `:draft`, cloned from Version 1
    - Version 2 is returned to the caller
  covers:
    - editor.version.req_single_draft
    - editor.version.req_version_auto_increment

- id: editor.version.scenario_ui_change_hash_unchanged
  given:
    - A draft with steps S1, S2 connected by C1
    - Previous published version has compiled_hash H1
  when:
    - The user moves S1 to a new position and renames a step group
    - The draft is compiled
  then:
    - The new compiled_hash equals H1
    - The publish modal shows "No execution changes since last publish"
  covers:
    - editor.version.req_hash_excludes_ui
    - editor.version.req_hash_unchanged_indicator

- id: editor.version.scenario_publish_pipeline
  given:
    - A valid draft with no validation errors
  when:
    - The user clicks "Publish"
  then:
    - The draft is persisted to the database
    - `validate_for_publish/2` runs and returns `:ok`
    - `publish_draft/2` compiles the workflow, sets status to `:published`, stores compiled_hash
    - Trigger registrations are synced
  covers:
    - editor.version.req_publish_pipeline
    - editor.version.req_compilation_pipeline
    - editor.version.req_trigger_sync_on_publish
~~~

## Verification

~~~spec-verification
- kind: source_file
  target: lib/fizz/workflows.ex
  covers:
    - editor.version.req_single_draft
    - editor.version.req_published_immutable
    - editor.version.req_publish_pipeline

- kind: source_file
  target: lib/fizz/workflows/compiler.ex
  covers:
    - editor.version.req_compilation_pipeline
    - editor.version.req_hash_excludes_ui

- kind: source_file
  target: lib/fizz/workflows/draft_validator.ex
  covers:
    - editor.version.req_publish_blocks_on_errors
~~~
