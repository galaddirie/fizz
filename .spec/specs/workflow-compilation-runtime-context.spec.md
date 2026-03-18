# Workflow Compilation And Runtime Context

This spec covers how authored workflow versions become executable workflows and
how runtime config resolution reads workflow state.

```spec-meta
id: workflows.compilation_runtime
kind: runtime
status: active
summary: Compilation strips UI-only authored metadata, seals execution-relevant content into a hashable artifact, and resolves step config from input, prior outputs, and run context.
surface:
  - docs/plans/compiler-and-runtime-context-design.md
  - docs/plans/workflow-definition-design.md
  - deps/runic/lib/runic.ex
  - deps/runic/lib/workflow/step.ex
  - .spec/decisions/programmatic-meta-ref-wiring.md
```

## Requirements

```spec-requirements
- id: workflows.compilation_runtime.pure_compile
  statement: Compilation is a pure transform from an authored definition version to an executable workflow plus a `compiled_hash`.
  priority: must
  stability: stable

- id: workflows.compilation_runtime.normalization
  statement: The compiler preserves execution-relevant step ids, type ids, config, topology, and handle names while stripping UI-only fields before execution assembly.
  priority: must
  stability: stable

- id: workflows.compilation_runtime.step_groups_ignored
  statement: In v1, `step_groups` never enter the IR or executable graph and are excluded from `compiled_hash`.
  priority: must
  stability: stable

- id: workflows.compilation_runtime.precompiled_expressions
  statement: Expressions are compiled into access plans at publish time and are not re-parsed on every workflow execution.
  priority: must
  stability: stable

- id: workflows.compilation_runtime.runtime_context
  statement: Runtime config resolution reads from the current step input, referenced upstream step outputs, and platform values injected through `run_context`, rather than from a standalone mutable state bag.
  priority: must
  stability: stable

- id: workflows.compilation_runtime.output_capture
  statement: Upstream step outputs used by downstream expressions are captured through Runic accumulator state so they survive checkpoint and restore.
  priority: must
  stability: stable

- id: workflows.compilation_runtime.meta_ref_wiring
  statement: Programmatically assembled workflows must generate quoted Runic components with literal `state_of()` and `context()` references so Runic records meta refs through its normal compile path; direct map access into `meta_ctx` is not a valid dependency declaration mechanism.
  priority: must
  stability: stable

- id: workflows.compilation_runtime.closure_bindings
  statement: Compiler-generated closures may capture only the plain maps, lists, and scalars needed at runtime, and must not capture internal IR structs whose shape can drift across deploys.
  priority: must
  stability: stable

- id: workflows.compilation_runtime.hash_scope
  statement: `compiled_hash` covers only execution-relevant content so runtime-equivalent versions compare equal despite UI-only edits.
  priority: must
  stability: stable

- id: workflows.compilation_runtime.compiler_version
  statement: Compiled artifacts carry a compiler version, and incompatible compiled artifacts must be rebuilt from the authored document instead of trusted across semantic changes.
  priority: should
  stability: stable
```

## Scenarios

```spec-scenarios
- id: workflows.compilation_runtime.ui_only_edit
  given:
    - two authored versions differ only in position, notes, viewport, settings, or step group metadata
  when:
    - both versions are compiled
  then:
    - their executable payload is equivalent
    - their `compiled_hash` matches
  covers:
    - workflows.compilation_runtime.normalization
    - workflows.compilation_runtime.step_groups_ignored
    - workflows.compilation_runtime.hash_scope

- id: workflows.compilation_runtime.resolve_step_outputs
  given:
    - a downstream step references outputs from upstream steps in its config
  when:
    - the downstream step resolves config at runtime
  then:
    - referenced step outputs are read from accumulator-backed runtime state
    - workflow and env metadata come from `run_context`
  covers:
    - workflows.compilation_runtime.runtime_context
    - workflows.compilation_runtime.output_capture

- id: workflows.compilation_runtime.meta_refs_declared
  given:
    - a compiled step depends on upstream step output or a run-context value
  when:
    - the compiler assembles the Runic component
  then:
    - the generated component carries explicit Runic meta references through quoted `state_of()` or `context()` calls
    - the component does not rely on ad hoc `meta_ctx` map lookups to declare dependencies
  covers:
    - workflows.compilation_runtime.meta_ref_wiring

- id: workflows.compilation_runtime.compiler_bump
  given:
    - a previously published version carries an older compiler version
  when:
    - the platform wakes or resumes the workflow under newer compiler semantics
  then:
    - the authored document remains the source of truth
    - the executable artifact is recompiled instead of trusted as-is
  covers:
    - workflows.compilation_runtime.compiler_version
```

## Verification

```spec-verification
- kind: doc_file
  target: docs/plans/compiler-and-runtime-context-design.md
  covers:
    - workflows.compilation_runtime.pure_compile
    - workflows.compilation_runtime.normalization
    - workflows.compilation_runtime.step_groups_ignored
    - workflows.compilation_runtime.precompiled_expressions
    - workflows.compilation_runtime.runtime_context
    - workflows.compilation_runtime.output_capture
    - workflows.compilation_runtime.meta_ref_wiring
    - workflows.compilation_runtime.closure_bindings
    - workflows.compilation_runtime.hash_scope
    - workflows.compilation_runtime.compiler_version
    - workflows.compilation_runtime.ui_only_edit
    - workflows.compilation_runtime.resolve_step_outputs
    - workflows.compilation_runtime.meta_refs_declared
    - workflows.compilation_runtime.compiler_bump

- kind: doc_file
  target: docs/plans/workflow-definition-design.md
  covers:
    - workflows.compilation_runtime.step_groups_ignored
    - workflows.compilation_runtime.hash_scope

- kind: source_file
  target: deps/runic/lib/runic.ex
  covers:
    - workflows.compilation_runtime.meta_ref_wiring

- kind: source_file
  target: deps/runic/lib/workflow/step.ex
  covers:
    - workflows.compilation_runtime.meta_ref_wiring

- kind: doc_file
  target: .spec/decisions/programmatic-meta-ref-wiring.md
  covers:
    - workflows.compilation_runtime.meta_ref_wiring
    - workflows.compilation_runtime.closure_bindings
```

## Exceptions

```spec-exceptions
- id: workflows.compilation_runtime.impl_pending
  note: The repository does not yet contain `Fizz.Workflows.Compiler`, runtime resolver modules, or a compiled-artifact schema that enforces this contract in code.
  relates_to:
    - workflows.compilation_runtime.pure_compile
    - workflows.compilation_runtime.precompiled_expressions
    - workflows.compilation_runtime.meta_ref_wiring
    - workflows.compilation_runtime.closure_bindings
    - workflows.compilation_runtime.compiler_version
```
