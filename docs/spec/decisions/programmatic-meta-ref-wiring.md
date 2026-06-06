# Programmatic Meta-Ref Wiring

Status: accepted

## Context

The workflow compiler assembles Runic components programmatically, but local
Runic currently discovers `state_of()` and `context()` dependencies by walking
quoted AST during macro expansion.

Directly reading `meta_ctx` in a runtime closure would bypass that discovery and
produce components with missing meta-ref edges.

## Decision

Compiled workflow components will be generated as quoted Runic DSL fragments
with literal `state_of()` and `context()` calls, then evaluated into Runic
component structs.

The compiler will not rely on:

- ad hoc `meta_ctx` map access as a dependency declaration mechanism
- post-construction mutation of component structs
- a hypothetical upstream `meta_refs` option that does not exist in the local
  Runic macro API

Compiler-generated closures must capture only plain maps, lists, and scalars,
not internal IR structs.

## Consequences

- Meta-ref edges continue to be built through Runic's existing public compile
  path.
- Programmatic assembly stays aligned with the public DSL instead of mutating
  internals after construction.
- Closure compatibility across deploys improves because IR struct shape changes
  are not serialized into workflow checkpoints.

## Related decisions

- `runic-as-execution-kernel.md` — establishes Runic as the target compilation
  kernel
- `expression-filter-catalog.md` — the expression surface whose compiled form
  must respect these wiring rules

## Sources

- `docs/plans/compiler-and-runtime-context-design.md`
- `docs/plans/runic-research.md`
- `deps/runic/lib/runic.ex`
- `deps/runic/lib/workflow/step.ex`
