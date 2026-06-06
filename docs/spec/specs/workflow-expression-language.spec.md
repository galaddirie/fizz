# Workflow Expression Language

This spec covers the durable user-facing expression surface used inside workflow
step configuration.

```spec-meta
id: workflows.expression_language
kind: policy
status: active
summary: Workflow expressions use a constrained Liquid-style language with explicit namespaces, typed value modes, and publish-time validation.
surface:
  - docs/plans/expression-design.md
  - docs/plans/compiler-and-runtime-context-design.md
  - deps/solid/lib/solid.ex
  - deps/solid/lib/solid/standard_filter.ex
  - docs/spec/decisions/expression-filter-catalog.md
```

## Requirements

```spec-requirements
- id: workflows.expression_language.engine
  statement: Workflow expressions use Solid as the implementation engine while exposing a constrained Liquid-style authoring surface with no arbitrary Elixir execution.
  priority: must
  stability: stable

- id: workflows.expression_language.namespaces
  statement: The canonical root namespaces are `input`, `steps`, `workflow`, and `env`, and user-facing documentation should prefer `input` and `steps` over older aliases.
  priority: must
  stability: stable

- id: workflows.expression_language.access
  statement: Expressions support both dot access and bracket access, and step references resolve through step ids rather than step type ids.
  priority: must
  stability: stable

- id: workflows.expression_language.modes
  statement: A field containing exactly one naked output expression preserves the native value type, mixed template content renders to string, and predicate fields resolve to boolean rather than exposing arbitrary code syntax.
  priority: must
  stability: stable

- id: workflows.expression_language.rename_sensitivity
  statement: Because step references resolve by step id, renaming a step changes the identifier that downstream expressions must reference.
  priority: must
  stability: stable

- id: workflows.expression_language.validation_timing
  statement: Draft saves may accept incomplete expressions, while publish-time validation must parse expressions, validate filters, and reject invalid step references.
  priority: must
  stability: stable

- id: workflows.expression_language.filter_catalog
  statement: The supported v1 filter catalog is bounded and exact. Allowed Solid built-ins are `default`, `append`, `prepend`, `upcase`, `downcase`, `strip`, `replace`, `split`, `join`, `first`, `last`, `size`, `compact`, `map`, `sort`, `sort_natural`, `uniq`, `where`, `plus`, `minus`, `times`, `divided_by`, `modulo`, `abs`, `at_least`, `at_most`, `round`, `ceil`, `floor`, `date`, `slice`, `truncate`, `truncatewords`, `url_encode`, and `url_decode`. Required Fizz custom filters are `json`, `parse_json`, `to_int`, `to_float`, `to_bool`, `dig`, `pluck`, `sort_by`, `sort_by_desc`, `where_eq`, `where_ne`, `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `blank`, `present`, and `slugify`.
  priority: must
  stability: stable

- id: workflows.expression_language.strict_filters
  statement: Publish-time expression validation must run with strict filter validation so unsupported filters fail publication instead of silently rendering through fallback behavior.
  priority: must
  stability: stable

- id: workflows.expression_language.runtime_fast_path
  statement: Simple namespace lookups with no filter chain should resolve by direct path access at runtime, while filtered or mixed templates resolve through the parsed Solid template.
  priority: should
  stability: stable
```

## Scenarios

```spec-scenarios
- id: workflows.expression_language.native_value
  given:
    - a config field contains only `{{ input.orders }}`
  when:
    - the workflow resolves the field at runtime
  then:
    - the field resolves to the native list or map value instead of a stringified rendering
  covers:
    - workflows.expression_language.modes

- id: workflows.expression_language.template_string
  given:
    - a config field mixes literal text and output tags
  when:
    - the workflow resolves the field at runtime
  then:
    - the result is a string
  covers:
    - workflows.expression_language.modes

- id: workflows.expression_language_step_rename
  given:
    - an expression references `steps.fetch_order.body`
  when:
    - the referenced step is renamed and its generated id changes
  then:
    - the expression must reference the new step id to remain valid
  covers:
    - workflows.expression_language.access
    - workflows.expression_language.rename_sensitivity

- id: workflows.expression_language.publish_validation
  given:
    - a draft contains expressions in step config
  when:
    - the user publishes the workflow
  then:
    - expressions are parsed and validated
    - invalid filters or invalid step references block publication
  covers:
    - workflows.expression_language.validation_timing

- id: workflows.expression_language.unsupported_filter
  given:
    - a draft expression uses a filter outside the supported catalog
  when:
    - the user publishes the workflow
  then:
    - strict filter validation rejects the expression
    - publication is blocked until the expression uses a supported filter or a dedicated workflow step instead
  covers:
    - workflows.expression_language.filter_catalog
    - workflows.expression_language.strict_filters
```

## Verification

```spec-verification
- kind: doc_file
  target: docs/plans/expression-design.md
  covers:
    - workflows.expression_language.engine
    - workflows.expression_language.namespaces
    - workflows.expression_language.access
    - workflows.expression_language.modes
    - workflows.expression_language.rename_sensitivity
    - workflows.expression_language.validation_timing
    - workflows.expression_language.filter_catalog
    - workflows.expression_language.native_value
    - workflows.expression_language.template_string
    - workflows.expression_language_step_rename

- kind: doc_file
  target: docs/plans/compiler-and-runtime-context-design.md
  covers:
    - workflows.expression_language.namespaces
    - workflows.expression_language.validation_timing
    - workflows.expression_language.runtime_fast_path
    - workflows.expression_language.publish_validation

- kind: source_file
  target: deps/solid/lib/solid.ex
  covers:
    - workflows.expression_language.strict_filters

- kind: source_file
  target: deps/solid/lib/solid/standard_filter.ex
  covers:
    - workflows.expression_language.filter_catalog

- kind: doc_file
  target: spec/decisions/expression-filter-catalog.md
  covers:
    - workflows.expression_language.filter_catalog
    - workflows.expression_language.strict_filters
    - workflows.expression_language.unsupported_filter
```

## Exceptions

```spec-exceptions
- id: workflows.expression_language.auto_rename_pending
  note: Automatic expression rewriting on step rename is explicitly deferred; v1 expects rename-sensitive references to be updated outside the spec contract.
  relates_to:
    - workflows.expression_language.rename_sensitivity
```
