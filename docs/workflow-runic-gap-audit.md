# Workflow Compiler Runic Gap Audit

This note captures the current gap between the authored step library and what
`Fizz.Workflows.Compiler` actually lowers into runnable `Runic.Workflow`
components today.

It is intentionally focused on execution semantics, not editor concerns.

## Current Status

The compiler currently does these things well:

- Normalizes authored workflow versions into plain-map IR.
- Precompiles expressions into access plans.
- Assembles most authored steps as generic `Runic.step(...)` nodes.
- Captures referenced upstream outputs with companion `Runic.accumulator(...)`
  nodes so `steps.<uuid>.*` expressions resolve at runtime.
- Uses `Workflow.add(component, to: [parent_a, parent_b, ...])` so Runic inserts
  an implicit join for simple multi-parent convergence.

That means straight-line workflows and basic "wait for both parents before
running this next step" flows are runnable today.

## Missing Or Partial Step-Library Semantics

### 1. `splitter` is not lowered to `Runic.map/2`

Current behavior:

- The compiler assembles `splitter` as a plain `Runic.step`.
- `Fizz.Steps.Executors.Splitter.execute/3` returns a list, but that list is
  emitted as a single fact.

What is missing:

- Lower authored `splitter` steps to `Runic.map/2`.
- Fan-out semantics where each element becomes its own downstream execution.

Impact:

- A workflow like `manual_input -> splitter -> math -> aggregator` does not
  process one item at a time.
- Downstream steps receive the whole list, not one mapped element.

Needed Runic primitive:

- `Runic.map/2`

### 2. `aggregator` is not lowered to `Runic.reduce/3`

Current behavior:

- The compiler assembles `aggregator` as a plain `Runic.step`.
- `Fizz.Steps.Executors.Aggregator.execute/3` can still aggregate an eager list,
  but it is not acting as a true fan-in over mapped outputs.

What is missing:

- Lower authored `aggregator` steps to `Runic.reduce/3`.
- When downstream of a `splitter`, wire the reducer with the upstream map name
  so it consumes all mapped element outputs.

Impact:

- Aggregate steps only work when the full list is already present in one fact.
- They do not validate real map/reduce compilation semantics.

Needed Runic primitive:

- `Runic.reduce/3`

### 3. `condition` is not lowered to `Runic.rule/1`

Current behavior:

- The compiler assembles `condition` as a plain `Runic.step`.
- The executor returns `{:ok, input}` or `{:skip, :condition_false}`.

What is missing:

- Lower authored condition nodes to `Runic.rule(...)`.
- Branch-aware routing for true/false outputs.

Impact:

- The current compiler can skip a step execution, but it does not model
  condition branching as first-class workflow graph semantics.
- True/false handle wiring is not represented in the executable graph.

Needed Runic primitive:

- `Runic.rule/1`

### 4. `switch` is not lowered to multi-rule branching

Current behavior:

- The compiler assembles `switch` as a plain `Runic.step`.
- The executor returns `{:branch, output_name, input}` as data.

What is missing:

- Lower switch cases to multiple `Runic.rule(...)` branches.
- Emit branch-specific graph edges from the authored output handles.

Impact:

- Branch selection is just a tagged tuple in a fact.
- Downstream authored connections do not route by case output.

Needed Runic primitive:

- `Runic.rule/1`

### 5. Connection handles are preserved in IR but ignored during assembly

Current behavior:

- `source_output` and `target_input` are normalized and hashed.
- The assembler only connects components by parent step id.

What is missing:

- Compiler logic that interprets authored handles when building the Runic graph.
- Routing by branch/output name.

Impact:

- Control-flow steps cannot express their authored branch semantics at runtime.
- Multi-port or handle-sensitive steps will compile, but not faithfully.

Needed support:

- Not a new Runic primitive by itself.
- This is compiler wiring work on top of `Runic.rule/1`, joins, and normal
  graph edges.

### 6. Explicit `join` steps are only partially meaningful today

Current behavior:

- If a step has multiple parents, `Workflow.add(..., to: parents)` creates a
  Runic join automatically.
- An authored `join` step is then assembled as a normal step after that join.

What is missing:

- Full fan-out aware join behavior that pairs correctly with mapped branches.
- Clear lowering rules for authored join modes like `zip_nil`,
  `zip_shortest`, `zip_cycle`, and `cartesian` in real split/join workflows.

Impact:

- Simple parent synchronization works.
- The interesting join mechanics depend on real `Runic.map/2` fan-out upstream,
  which the compiler does not currently emit.

Needed Runic primitives:

- Existing implicit `Runic.Workflow.Join`
- In practice, also `Runic.map/2` upstream

### 7. Subnode / slot-based steps are not assembled

Current behavior:

- The normalizer carries `node_role` and `config_schema`.
- The compiler does not interpret `role: :subnode` or `@subnode_slots`.

Affected step families:

- `ai_agent`
- `openai_model`
- `anthropic_model`
- `ai_prompt_template`
- `ai_tool_http`

What is missing:

- Nested graph assembly for root nodes with slot-scoped child nodes.
- Slot-to-input wiring and cardinality enforcement at compile time.

Impact:

- These steps may validate individually, but the authored composite structure is
  not executable as designed.

Needed Runic support:

- Mostly compiler work rather than a single new primitive.
- Likely nested workflow/pipeline composition using existing Runic workflow
  assembly APIs.

### 8. `wait` is still a blocking executor, not a durable runtime primitive

Current behavior:

- `Fizz.Steps.Executors.Wait.execute/3` calls `Process.sleep/1`.

What is missing:

- A non-blocking, durable wait model integrated with the future runner/store.
- Resume-safe timer scheduling instead of sleeping inside a step function.

Impact:

- Acceptable for now while we build this out later

Needed support:

- This is primarily a runtime/platform feature, not just compiler lowering.
- It likely needs runner/timer integration more than a new Runic graph
  primitive.

## Runic Primitives We Already Rely On

- `Runic.step/2` for generic step execution.
- `Runic.accumulator/3` for step-output capture used by runtime expressions.
- Implicit `Runic.Workflow.Join` created by `Workflow.add(component, to: [...])`
  for simple multi-parent synchronization.

## Runic Primitives We Still Need To Lower Into

- `Runic.map/2`
  Required for real fan-out semantics from `splitter`.

- `Runic.reduce/3`
  Required for real fan-in semantics from `aggregator`.

- `Runic.rule/1`
  Required for authored control-flow semantics from `condition` and `switch`.

## Practical Testing Guidance

What is worth testing now:

- Compile + run for straight-line workflows.
- Compile + run for simple multi-parent convergence where a downstream step
  should wait for all parents.
- Expression resolution against upstream step outputs captured in accumulators.

What is not a trustworthy integration test yet:

- `splitter -> per-item work -> aggregator`
- Branch-routing behavior for `condition` and `switch`
- Fan-out aware join modes such as zip/cartesian semantics
- Slot/subnode execution for composite AI steps

Those cases need compiler support first, otherwise a failing test would mostly
be proving a known lowering gap rather than a bug in the individual step
executors.

## Recommended Next Compiler Milestones

1. Add special lowering for `splitter` to `Runic.map/2`.
2. Add special lowering for `aggregator` to `Runic.reduce/3`.
3. Add handle-aware control-flow lowering for `condition` and `switch` via
   `Runic.rule/1`.
4. Make connection handles (`source_output`, `target_input`) semantically active
   in the assembler.
5. Add slot/subnode assembly for composite root steps like `ai_agent`.
6. Replace blocking `wait` execution with durable timer integration in the
   future runner. 
7. exhaustive tests 
