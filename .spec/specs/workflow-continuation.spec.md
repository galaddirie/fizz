# Workflow Continuation

This spec covers the ContinueAsNew boundary used to roll long-lived workflow
history into a fresh execution without changing the logical workflow identity.

```spec-meta
id: workflows.continuation
kind: workflow
status: active
summary: ContinueAsNew creates a fresh child run from explicit carry-forward state at a safe execution boundary and records lineage in control-plane metadata.
surface:
  - docs/plans/durable-workflow-system-design.md
  - docs/plans/compiler-and-runtime-context-design.md
  - .spec/decisions/continue-as-new-boundary.md
```

## Requirements

```spec-requirements
- id: workflows.continuation.explicit_boundary
  statement: ContinueAsNew is an explicit runtime action taken at a quiescent checkpoint boundary after durable state is committed, and it is not an automatic side effect of the store adapter checkpoint path.
  priority: must
  stability: stable

- id: workflows.continuation.carry_forward
  statement: The child execution receives only an explicit serializable carry-forward payload plus selected workflow metadata, and does not implicitly inherit in-flight runnables, raw graph internals, or hidden accumulator state.
  priority: must
  stability: stable

- id: workflows.continuation.version
  statement: ContinueAsNew preserves the same workflow definition and definition version unless a separate migration path explicitly chooses otherwise.
  priority: must
  stability: stable

- id: workflows.continuation.parent_state
  statement: The parent execution becomes terminal as `continued` after the handoff and remains inspectable as a historical artifact.
  priority: must
  stability: stable

- id: workflows.continuation.lineage
  statement: Control-plane metadata must record parent-child continuation lineage so operators can navigate the full logical workflow history across runs.
  priority: must
  stability: stable

- id: workflows.continuation.recommendation
  statement: Log-size or retention policies may recommend ContinueAsNew, but the decision to continue remains outside the persistence layer and must be surfaced at the workflow/runtime level.
  priority: should
  stability: stable
```

## Scenarios

```spec-scenarios
- id: workflows.continuation.compact_long_history
  given:
    - a workflow run has accumulated enough history that continuation is requested
    - the workflow has reached a safe checkpoint boundary
  when:
    - ContinueAsNew is executed
  then:
    - the parent run checkpoints and transitions to `continued`
    - a child run is created from explicit carry-forward state
    - lineage metadata links the two runs
  covers:
    - workflows.continuation.explicit_boundary
    - workflows.continuation.carry_forward
    - workflows.continuation.parent_state
    - workflows.continuation.lineage

- id: workflows.continuation.no_hidden_handoff
  given:
    - a workflow run has pending in-flight work or internal graph state not selected for carry-forward
  when:
    - ContinueAsNew is prepared
  then:
    - only the explicit carry-forward payload is eligible to cross into the child run
    - implicit transfer of pending runnables or hidden runtime internals is not part of the contract
  covers:
    - workflows.continuation.carry_forward

- id: workflows.continuation.same_definition
  given:
    - a workflow run continues as new for history compaction
  when:
    - the child run starts
  then:
    - it starts from the same workflow definition identity and version unless a separate migration flow has been invoked
  covers:
    - workflows.continuation.version
```

## Verification

```spec-verification
- kind: doc_file
  target: docs/plans/durable-workflow-system-design.md
  covers:
    - workflows.continuation.explicit_boundary
    - workflows.continuation.parent_state
    - workflows.continuation.recommendation
    - workflows.continuation.compact_long_history

- kind: doc_file
  target: docs/plans/compiler-and-runtime-context-design.md
  covers:
    - workflows.continuation.version

- kind: doc_file
  target: .spec/decisions/continue-as-new-boundary.md
  covers:
    - workflows.continuation.explicit_boundary
    - workflows.continuation.carry_forward
    - workflows.continuation.version
    - workflows.continuation.parent_state
    - workflows.continuation.lineage
    - workflows.continuation.recommendation
    - workflows.continuation.compact_long_history
    - workflows.continuation.no_hidden_handoff
    - workflows.continuation.same_definition
```

## Exceptions

```spec-exceptions
- id: workflows.continuation.impl_pending
  note: The repository does not yet contain workflow-run schemas, continuation APIs, or operator lineage views that enforce this continuation contract in code.
  relates_to:
    - workflows.continuation.explicit_boundary
    - workflows.continuation.lineage
```
