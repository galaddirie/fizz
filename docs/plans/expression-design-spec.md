# Expression Design Guide

This document defines the expression language we want to expose to users.

Scope:

- `Solid` as the implementation engine
- Liquid-style syntax on the user side
- supported expression shapes
- supported filters
- validation and rendering rules

Out of scope:

- workflow state storage
- context construction
- branch scoping
- runtime state management

Those concerns should be documented separately.

---

## Decision

We should use `Solid` as the expression engine and expose a constrained Liquid-style authoring language to users.

Why `Solid`:

- safe template engine with no arbitrary Elixir execution
- familiar `{{ ... }}` and `{% ... %}` syntax
- good fit for string interpolation plus light data transformation
- extensible through custom filters

Why a constrained surface:

- step config expressions should stay readable
- behavior should be easy to validate and preview
- we should not expose the full complexity of a programming language inside config fields

The user-facing contract should be:

- expressions look like Liquid
- filters are the primary extension mechanism
- arbitrary code is never allowed

---

## Canonical User Syntax

Users should write expressions using Liquid tags:

- output tags: `{{ ... }}`
- control tags: `{% ... %}`

Examples:

```liquid
{{ input.customer.email }}
{{ workflow.id }}
{{ steps.fetch_orders.body.id }}
Hello {{ input.first_name }} {{ input.last_name }}
{% if input.vip %}priority{% else %}normal{% endif %}
```

### Canonical naming

We should standardize on:

- `input` for the current value
- `steps` for step references

Compatibility aliases can exist, but the docs and UI should prefer:

- `input`, not `json`
- `steps`, not `nodes`

This keeps the syntax aligned with the rest of the product vocabulary.

### Dot access and bracket access should both be supported

Dot access is the cleanest form when the path segments are identifier-safe:

```liquid
{{ steps.fetch_orders.body }}
{{ input.customer.email }}
```

Bracket access should also be supported for:

- display labels
- keys with spaces or punctuation
- array indexes

Examples:

```liquid
{{ steps["Fetch Orders"].body }}
{{ input["customer name"] }}
{{ input.orders[0].id }}
```

Step IDs are still generated from the current display label, so dot-accessed step references can change when a step is renamed.

Examples:

- `"Fetch Order"` -> `fetch_order`
- `"Fetch Order 2"` -> `fetch_order_2`
- renaming `"Fetch Order 2"` to `"Fetch Order Canada"` changes the step ID to `fetch_order_canada`

This is different from the step `type_id`.

- both `"Fetch Order"` and `"Fetch Order Canada"` may have the same step `type_id`, such as `http_request`
- a step `id` can initially match its `type_id`, but they are not the same concept

### Automatic rename updates

**Scope: Post-v1 enhancement.** This feature requires parsing all expressions across all step configs, matching the first path segment after the root namespace, and rewriting — which is non-trivial when expressions may be partially written during a draft save. For v1, the editor should show a warning when a step is renamed that existing expressions may reference the old name. Automated rewriting is deferred.

If the editor supports rename-aware expression updates, it should rewrite only the first access segment after these root namespaces:

- `steps`
- `nodes`
- `input`
- `json`

This should work for both dot and bracket access forms.

Examples:

```liquid
{{ steps.fetch_order_2.body }}            -> {{ steps.fetch_order_canada.body }}
{{ steps["Fetch Order 2"].body }}       -> {{ steps["Fetch Order Canada"].body }}
```

The rewrite should be shallow on purpose:

- rewrite the first segment after the root namespace
- leave the rest of the path unchanged

So for:

```liquid
{{ steps.fetch_order.body.id }}
```

renaming the referenced step should update only `fetch_order`, not `body.id`.

---

## Expression Modes

Not every field should behave the same way. We should support three authoring modes.

### 1. Value Expressions

Use a single naked `{{ ... }}` expression when the field should resolve to a native value:

```liquid
{{ input.orders }}
{{ input.total | to_float }}
{{ steps.lookup_customer.body }}
```

Expected result types:

- string
- number
- boolean
- list
- map
- `nil`

Design rule:

- if the field contains exactly one output tag and nothing else, preserve the native type
- do not stringify lists and maps in this mode

This matches the old prototype's best idea and is important for config fields like:

- request bodies
- arrays
- numeric settings
- booleans

### 2. Template Expressions

Use mixed text plus `{{ ... }}` and optional `{% if %}` blocks when the field should always resolve to a string:

```liquid
https://api.example.com/customers/{{ input.customer_id }}
Hello {{ input.first_name }}
{% if input.vip %}priority{% else %}normal{% endif %}
```

Design rule:

- any field with surrounding text is rendered as a string

### 3. Predicate Expressions

Predicate fields should resolve to a boolean.

Because Liquid output tags are not JavaScript or Elixir expressions, we should not encourage syntax like:

```liquid
{{ input.total > 100 }}
```

Instead, predicate fields should use one of these valid patterns:

```liquid
{{ input.total | gt: 100 }}
{{ input.status | eq: "paid" }}
{{ input.email | blank }}
{{ input.email | present }}
```

For template-style conditionals, normal Liquid control tags are still valid:

```liquid
{% if input.total > 100 %}true{% else %}false{% endif %}
```

But that should not be the primary documented style for boolean config fields. Filter-based predicates are shorter, clearer, and easier to validate consistently.

---

## What We Want To Support

### Output interpolation

```liquid
{{ input.name }}
{{ workflow.id }}
{{ steps.fetch_orders.body }}
```

### Dot-path access

```liquid
{{ input.customer.email }}
{{ steps.fetch_orders.body.status }}
```

Dot notation should be the canonical documented style.

### Bracket access

```liquid
{{ steps["Fetch Orders"].body }}
{{ input["customer name"] }}
{{ input.orders[0].id }}
```

Bracket access should be documented as the general escape hatch for:

- display labels
- non-identifier map keys
- array indexing

### Filter pipelines

```liquid
{{ input.total | to_float | round_to: 2 }}
{{ input.orders | pluck: "id" | json }}
{{ input.items | where_eq: "status", "active" }}
```

### Conditional blocks in string templates

```liquid
{% if input.vip %}
  priority
{% else %}
  normal
{% endif %}
```

This is useful in:

- prompt templates
- message templates
- URL/query fragments
- string output formatting

---

## What We Do Not Want To Support

We should keep the language small.

Do not document or encourage:

- arbitrary Elixir code
- JavaScript-style expressions
- function calls like `foo(bar)`
- file or network access
- includes, partials, or template imports
- stateful template features such as counters
- large template programs embedded in config

Specifically, these should be considered invalid user style:

```liquid
{{ input.total > 100 }}
{{ input.first_name + " " + input.last_name }}
{{ MyApp.some_fun(input) }}
```

If users need transformation, the path should be:

- a filter
- a dedicated workflow step
- a richer template field with documented Liquid constructs

Not embedded code.

---

## Filter Strategy

Filters are the right extension point for our expression system.

Rules for filters:

- pure
- side-effect free
- deterministic for the same input
- safe on bad input
- composable in pipelines

We should expose two categories:

- standard Solid/Liquid filters that are already intuitive
- Fizz-specific custom filters for workflow authoring

---

## Proposed Supported Filter Set

The old prototype already explored a useful base set. We should keep most of it.

### Conversion

```liquid
{{ input.total | to_int }}
{{ input.total | to_float }}
{{ input.enabled | to_bool }}
{{ input.payload | to_string }}
{{ input.payload | json }}
{{ input.raw | parse_json }}
```

Recommended filters:

- `json`
- `parse_json`
- `to_int`
- `to_float`
- `to_string`
- `to_bool`

### Data access and shaping

```liquid
{{ input.customer | dig: "address.city" }}
{{ input.orders | pluck: "id" }}
{{ input.orders | group_by: "status" }}
{{ input.orders | sort_by: "created_at" }}
{{ input.orders | sort_by_desc: "total" }}
{{ input.orders | where_eq: "status", "paid" }}
{{ input.orders | where_ne: "status", "cancelled" }}
{{ input.orders | unique_by: "id" }}
{{ input.orders | index_by: "id" }}
{{ input.customer | keys }}
{{ input.customer | values }}
{{ input.customer | pick: "name,email" }}
{{ input.customer | omit: "password,secret" }}
```

Recommended filters:

- `dig`
- `pluck`
- `group_by`
- `sort_by`
- `sort_by_desc`
- `where_eq`
- `where_ne`
- `unique_by`
- `index_by`
- `keys`
- `values`
- `merge`
- `pick`
- `omit`

### String helpers

```liquid
{{ input.title | slugify }}
{{ input.body | truncate_words: 20 }}
{{ input.reference | extract: "\\d+" }}
{{ input.reference | match: "^ORD-" }}
{{ input.number | pad_left: 8, "0" }}
```

Recommended filters:

- `slugify`
- `truncate_words`
- `extract`
- `match`
- `pad_left`
- `pad_right`

### Math helpers

```liquid
{{ input.total | abs }}
{{ input.total | ceil }}
{{ input.total | floor }}
{{ input.total | round_to: 2 }}
{{ input.score | clamp: 0, 100 }}
```

Recommended filters:

- `abs`
- `ceil`
- `floor`
- `round_to`
- `clamp`

### Date formatting helpers

```liquid
{{ input.created_at | format_date: "%Y-%m-%d" }}
{{ input.created_at | add_days: 7 }}
{{ input.created_at | add_hours: 2 }}
{{ input.created_at | add_minutes: 30 }}
```

Recommended filters:

- `format_date`
- `add_days`
- `add_hours`
- `add_minutes`

### Utility helpers

```liquid
{{ input.email | default: "unknown@example.com" }}
{{ input.nickname | coalesce: input.name }}
```

Recommended filters:

- `default`
- `coalesce`

### Hashing and encoding

```liquid
{{ input.token | sha256 }}
{{ input.payload | base64_encode }}
{{ input.payload | base64_decode }}
```

Recommended filters:

- `base64_encode`
- `base64_decode`
- `sha256`
- `md5`

Use `hmac_sha256` carefully. It is useful, but if a filter requires a secret input we should make sure the UI and docs position it as an advanced case.

---

## Missing Predicate Filters We Should Add

If we want a good user experience with Solid, we should add explicit comparison and presence filters.

Recommended additions:

- `eq`
- `ne`
- `gt`
- `gte`
- `lt`
- `lte`
- `contains`
- `blank`
- `present`

Examples:

```liquid
{{ input.total | gt: 100 }}
{{ input.status | eq: "paid" }}
{{ input.tags | contains: "vip" }}
{{ input.email | blank }}
{{ input.email | present }}
```

These filters let us support user-friendly predicate fields without inventing a second expression language on top of Liquid.

---

## Recommended User-Facing Rules

These should appear in product docs, tooltips, and examples.

### Rule 1: Use a naked expression for non-string values

Good:

```liquid
{{ input.orders }}
```

Avoid:

```liquid
Orders: {{ input.orders }}
```

if the field expects an array or object.

### Rule 2: Use filters instead of code

Good:

```liquid
{{ input.total | to_float | round_to: 2 }}
{{ input.total | gt: 100 }}
```

Avoid:

```liquid
{{ Number(input.total).toFixed(2) }}
{{ input.total > 100 }}
```

### Rule 3: Use dot or bracket access based on the path shape

Good:

```liquid
{{ steps.fetch_orders.body }}
{{ steps["Fetch Orders"].body }}
{{ input.orders[0].id }}
```

Use dot access for identifier-safe paths. Use bracket access for display labels, keys with spaces or punctuation, and array indexes.

### Rule 4: Keep expressions short

If the expression starts to look like a program, it should probably be:

- a dedicated transform step
- a helper filter
- a richer template field

Not a long inline expression.

---

## Validation And Rendering Rules

### Parse validation

We should validate expressions with `Solid.parse/1`.

This catches:

- malformed tags
- malformed filters
- invalid Liquid syntax

### Filter validation

Unknown filters should be treated as errors.

Recommended default:

- `strict_filters: true`

### Type preservation for naked expressions

If a field is exactly one output tag and nothing else, we should preserve the resolved type instead of stringifying it.

Implementation approach:

- parse once with `Solid.parse/1`
- if the parsed template is a single object node, read the value directly
- otherwise render normally as a string

This is the right behavior for config fields like:

- request JSON body
- arrays of IDs
- numeric thresholds
- booleans

### Recursive evaluation

Maps and lists should be evaluated recursively.

That means:

- strings with no Liquid tags stay unchanged
- strings with Liquid tags are evaluated
- nested map/list structures are walked deeply

This is especially useful for JSON-like config payloads.

### Timeouts and safety

Expression evaluation should be guarded by a timeout and run in a sandboxed way.

The expression layer should never allow:

- arbitrary module calls
- file access
- network access
- side effects

---

## Implementation Notes For Solid

Recommended implementation shape:

1. Detect whether a string contains Liquid tags.
2. Validate with `Solid.parse/1`.
3. Reuse the compiled template when rendering repeatedly.
4. Register `Fizz.Runtime.Expression.Filters` as the custom filter module.
5. Preserve native types for naked expressions.
6. Render mixed-content templates to strings with `Solid.render/3`.

This keeps the implementation simple and aligned with what Solid already does well.

---

## Suggested Product Examples

These are the kinds of examples we should standardize on in the UI.

### String template

```liquid
Hello {{ input.first_name }}, your order {{ input.order_number }} is ready.
```

### Native object value

```liquid
{{ steps.fetch_customer.body }}
```

### Numeric value

```liquid
{{ input.total | to_float | round_to: 2 }}
```

### Predicate value

```liquid
{{ input.total | gt: 100 }}
```

### Collection shaping

```liquid
{{ input.orders | where_eq: "status", "paid" | pluck: "id" }}
```

### Conditional string template

```liquid
{% if input.vip %}priority{% else %}normal{% endif %}
```

---

## Bottom Line

The user-facing expression language should be:

- Liquid-style
- Solid-backed
- filter-oriented
- safe
- small

The biggest design rule is to stay honest about what Solid is.

We should not document n8n-style or JavaScript-style expressions that look convenient but are not real Liquid syntax. If users write Liquid, and we extend it through a curated filter set, the system stays teachable and the implementation stays clean.
