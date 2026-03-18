# Workflow Definitions

This spec covers the durable authored source of truth for workflow definitions,
their version snapshots, and the draft-to-published lifecycle.

```spec-meta
id: workflows.definitions
kind: component
status: active
summary: Workflow definitions persist typed authored documents and advance through a controlled draft and publish lifecycle.
surface:
  - docs/plans/workflow-definition-design.md
  - docs/plans/compiler-and-runtime-context-design.md
  - lib/fizz/steps/registry.ex
```

## Requirements

```spec-requirements
- id: workflows.definitions.identity
  statement: A workflow definition row is the stable identity for an authored workflow, while version rows hold self-contained snapshots of the authored document over time.
  priority: must
  stability: stable

- id: workflows.definitions.snapshot_shape
  statement: A version snapshot persists first-class `steps`, `connections`, and `step_groups` collections plus `viewport` and `settings`, rather than storing the authored graph as an opaque blob.
  priority: must
  stability: stable

- id: workflows.definitions.step_groups_ui_only
  statement: In v1, `step_groups` are persisted editor metadata only and do not change executable workflow semantics.
  priority: must
  stability: stable

- id: workflows.definitions.step_ids
  statement: Step `id` values are unique, key-safe identifiers derived from the current step name, regenerate on rename, and remain distinct from the step `type_id`.
  priority: must
  stability: stable

- id: workflows.definitions.save_validation
  statement: Draft saves must accept incomplete authoring while still enforcing embed integrity, existing step references, registry-backed `type_id` validity, non-overlapping group membership, and an acyclic step graph.
  priority: must
  stability: stable

- id: workflows.definitions.publish_validation
  statement: Publishing must require all save-time validation plus config validation, credential accessibility, handle validation, at least one entry step, successful compilation, and a stored `compiled_hash`.
  priority: must
  stability: stable

- id: workflows.definitions.lifecycle
  statement: Each definition has one mutable draft at a time, publishing freezes that draft, later editing starts from a clone of the latest published version, and published rows are immutable at the application layer.
  priority: must
  stability: stable

- id: workflows.definitions.concurrent_editing
  statement: Concurrent draft editing uses full-document last-write-wins autosave semantics in v1.
  priority: should
  stability: stable
```

## Scenarios

```spec-scenarios
- id: workflows.definitions.create_initial_draft
  given:
    - a new workflow definition is created
  when:
    - the first version row is inserted
  then:
    - the version is created as draft `v1`
    - the embedded collections start as complete but empty authored state
  covers:
    - workflows.definitions.identity
    - workflows.definitions.snapshot_shape
    - workflows.definitions.lifecycle

- id: workflows.definitions.publish_from_draft
  given:
    - a draft version has passed save-time validation
  when:
    - the user publishes the draft
  then:
    - publish-time validation runs
    - the version is stamped with `published_at`, `published_by_user_id`, and `compiled_hash`
    - the published row becomes immutable at the application layer
  covers:
    - workflows.definitions.publish_validation
    - workflows.definitions.lifecycle

- id: workflows.definitions.rename_step
  given:
    - a definition contains a step with a generated name-derived id
  when:
    - the step is renamed
  then:
    - its step id is regenerated from the new name
    - connection and expression references are expected to follow the regenerated id rather than the prior display label
  covers:
    - workflows.definitions.step_ids

- id: workflows.definitions.archive_definition
  given:
    - a workflow definition has at least one published version
  when:
    - the operator archives the definition
  then:
    - the definition is marked archived and no new runs can start from it
    - existing active runs are unaffected
    - historical versions remain inspectable
  covers:
    - workflows.definitions.lifecycle

- id: workflows.definitions.clone_published_to_draft
  given:
    - a workflow definition has a published version and no current draft
  when:
    - the user initiates editing
  then:
    - a new draft version is created by cloning the latest published version's snapshot
    - the draft inherits the full steps, connections, step_groups, viewport, and settings
  covers:
    - workflows.definitions.lifecycle
    - workflows.definitions.snapshot_shape

- id: workflows.definitions.save_rejects_cyclic_graph
  given:
    - a draft contains steps with connections forming a cycle
  when:
    - the user saves the draft
  then:
    - save-time validation rejects the save with an acyclicity violation error
    - the draft is not persisted in its cyclic state
  covers:
    - workflows.definitions.save_validation

- id: workflows.definitions.concurrent_last_write_wins
  given:
    - two users concurrently edit the same draft version
  when:
    - both save at roughly the same time
  then:
    - the last save persisted wins with full-document replacement
    - no merge conflict is raised
  covers:
    - workflows.definitions.concurrent_editing
```

## Verification

```spec-verification
- kind: doc_file
  target: docs/plans/workflow-definition-design.md
  covers:
    - workflows.definitions.identity
    - workflows.definitions.snapshot_shape
    - workflows.definitions.step_groups_ui_only
    - workflows.definitions.step_ids
    - workflows.definitions.save_validation
    - workflows.definitions.publish_validation
    - workflows.definitions.lifecycle
    - workflows.definitions.concurrent_editing
    - workflows.definitions.create_initial_draft
    - workflows.definitions.publish_from_draft
    - workflows.definitions.rename_step

- kind: doc_file
  target: docs/plans/compiler-and-runtime-context-design.md
  covers:
    - workflows.definitions.step_groups_ui_only
    - workflows.definitions.publish_validation

- kind: source_file
  target: lib/fizz/steps/registry.ex
  covers:
    - workflows.definitions.save_validation
```

## Exceptions

```spec-exceptions
- id: workflows.definitions.impl_pending
  note: The repository does not yet contain the `Fizz.Workflows.*` schemas, migrations, or context modules that would enforce this definition/version contract in code.
  relates_to:
    - workflows.definitions.identity
    - workflows.definitions.snapshot_shape
    - workflows.definitions.save_validation
    - workflows.definitions.publish_validation
    - workflows.definitions.lifecycle
```
