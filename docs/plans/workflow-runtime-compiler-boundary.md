# Workflow Runtime Compiler Boundary Plan

Status date: 2026-05-28

## Goal

Reduce `Fizz.Workflows.Compiler.Assembler` responsibility without changing compiled workflow behavior.

## Non-Goals

- Do not change authored workflow semantics.
- Do not change expression syntax or filter behavior.
- Do not alter connection handle decisions except where `ConnectionPlan` already owns them.
- Do not mix compiler behavior fixes with extraction unless a characterization test proves the bug first.

## Plan

### Phase 1 - Characterization

Add or confirm tests around:

- switch branch routing
- split/join/aggregator scope planning
- runtime callback behavior
- expression detection and access-plan compilation
- compiled hash stability for execution-equivalent authored versions

Exit criteria: extraction has a safety net.

### Phase 2 - Scope Planner

Extract split/join/aggregator scope decisions into `Fizz.Workflows.Compiler.ScopePlanner`.

Exit criteria:

- planner inputs and outputs are explicit
- assembler asks for scope decisions instead of deriving all of them inline
- compiler semantics tests remain green

### Phase 3 - Runtime Callbacks

Extract runtime callback helpers into `Fizz.Workflows.Compiler.RuntimeCallbacks`.

Exit criteria:

- callback construction has one home
- closures capture only plain maps, lists, and scalars needed at runtime
- compiler runtime-context tests remain green

### Phase 4 - ConnectionPlan Cleanup

Make `ConnectionPlan` emit only indexes consumed by assembly, then remove unused fields.

Exit criteria:

- connection indexes are named by actual use
- no stale plan fields survive only because assembler used to need them

### Phase 5 - Switch Matching Source of Truth

Move switch branch matching into the switch executor module and reuse it from compiler/runtime helper code.

Exit criteria:

- switch matching has one implementation
- branch behavior is covered by compiler semantics tests

### Phase 6 - Expression Helper Ownership

Expose one expression detection/access-plan helper from `Fizz.Workflows.Expressions` and remove duplicate local versions.

Exit criteria:

- expression detection does not exist in multiple local helper variants
- expression tests and compiler tests agree on behavior

## Acceptance Criteria

- Compiler semantics tests pass before and after extraction.
- `Assembler` remains responsible for assembly, not planning every semantic detail.
- Switch matching has one source of truth.
- Expression detection has one source of truth.
- `compiled_hash` remains stable unless execution-relevant output intentionally changes.

## Test Commands

```bash
mix test test/fizz/workflows/compiler_test.exs
mix test test/fizz/workflows/compiler_semantics_test.exs
mix test test/fizz/workflows/compiler/assembler_context_test.exs
mix test test/fizz/workflows/expressions_test.exs
mix precommit
```

## Rollout / Rollback

Roll out after runtime safety work unless compiler work is isolated in a separate no-behavior-change PR. Rollback is code revert.

## Dependencies

- Green compiler characterization tests.
- Current connection-handle refactor direction.

