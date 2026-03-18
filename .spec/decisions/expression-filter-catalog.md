# Expression Filter Catalog

Status: accepted

## Context

The expression design notes described a large proposed filter surface but left
the final v1 catalog unresolved. An unbounded filter surface would make
validation, documentation, and drift detection too loose.

## Decision

The workflow expression system uses a bounded v1 catalog and validates it with
`strict_filters: true` at publish time.

Allowed Solid built-ins:

- `default`
- `append`
- `prepend`
- `upcase`
- `downcase`
- `strip`
- `replace`
- `split`
- `join`
- `first`
- `last`
- `size`
- `compact`
- `map`
- `sort`
- `sort_natural`
- `uniq`
- `where`
- `plus`
- `minus`
- `times`
- `divided_by`
- `modulo`
- `abs`
- `at_least`
- `at_most`
- `round`
- `ceil`
- `floor`
- `date`
- `slice`
- `truncate`
- `truncatewords`
- `url_encode`
- `url_decode`

Required Fizz custom filters:

- `json`
- `parse_json`
- `to_int`
- `to_float`
- `to_bool`
- `dig`
- `pluck`
- `sort_by`
- `sort_by_desc`
- `where_eq`
- `where_ne`
- `eq`
- `ne`
- `gt`
- `gte`
- `lt`
- `lte`
- `blank`
- `present`
- `slugify`

Everything outside this catalog is unsupported in v1.

## Consequences

- Publish-time validation can reject unsupported filters deterministically.
- More complex shaping work should move into dedicated workflow steps instead of
  filter sprawl.
- Future filter additions require an explicit catalog change rather than ad hoc
  implementation drift.

## Sources

- `docs/plans/expression-design.md`
- `docs/plans/compiler-and-runtime-context-design.md`
- `deps/solid/lib/solid.ex`
- `deps/solid/lib/solid/standard_filter.ex`
