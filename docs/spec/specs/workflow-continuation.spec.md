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
  - docs/spec/decisions/continue-as-new-boundary.md
  - docs/spec/decisions/per-execution-sqlite-store.md
  - docs/spec/decisions/postgres-control-plane.md
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

- id: workflows.continuation.stable_workflow_address
  statement: Each logical workflow maintains a stable `workflow_id` that persists across continuation boundaries. The control plane records the currently active `run_id` for each `workflow_id`, enabling callers to address signals to the logical workflow without tracking individual run transitions. Signals addressed to a `workflow_id` are routed to the active run's inbox; if the active run is mid-handoff, the signal is accepted into the incoming child's inbox once creation completes, or into the parent's inbox if handoff fails.
  priority: should
  stability: evolving

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

- id: workflows.continuation.pending_signals_not_inherited
  given:
    - a parent run has undelivered signals in its inbox at the time of ContinueAsNew
  when:
    - the continuation handoff completes
  then:
    - undelivered parent signals remain associated with the parent run_id
    - the child run starts with an empty signal inbox
  covers:
    - workflows.continuation.carry_forward
    - workflows.continuation.parent_state

- id: workflows.continuation.child_creation_failure
  given:
    - ContinueAsNew is triggered at a safe checkpoint boundary
    - child run creation fails due to a transient error
  when:
    - the handoff cannot complete
  then:
    - the parent run does not transition to `continued`
    - the parent remains in its prior state and the error is surfaced for retry or operator intervention
  covers:
    - workflows.continuation.explicit_boundary
    - workflows.continuation.parent_state

- id: workflows.continuation.signal_via_workflow_id
  given:
    - a logical workflow has continued from run A to run B
    - a caller sends a signal addressed to the stable workflow_id
  when:
    - the control plane resolves the active run for the workflow_id
  then:
    - the signal is routed to run B's inbox
    - the caller does not need to know about the continuation or track individual run_ids
  covers:
    - workflows.continuation.stable_workflow_address

- id: workflows.continuation.chained_lineage
  given:
    - workflow run A continues as run B, then run B continues as run C
  when:
    - each continuation records lineage metadata in the control plane
  then:
    - the lineage chain A to B to C is navigable
    - each run records its immediate parent and the chain is traversable for operator inspection
  covers:
    - workflows.continuation.lineage
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
  target: spec/decisions/continue-as-new-boundary.md
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
