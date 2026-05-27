# Node Executor Design Guide

## Core Principle

**Every input a node needs must be a config field.**

The `input` parameter exists only to populate `{{ json }}` in expressions. Most Executors should never read from `input` directly.

---

## The Golden Rule

```elixir
# ✗ WRONG - Reading from input
def execute(config, input, _execution) do
  value = input["someField"]  # Don't do this!
  # ...
end

# ✓ CORRECT - Everything from config
def execute(config, _input, _execution) do
  value = config["value"]  # Expression already resolved
  # ...
end
```

---

## How Data Flow Works

```
┌─────────────────────────────────────────────────────────────────┐
│                        RUNTIME FLOW                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. gather_inputs(node_id)                                       │
│     └─> Returns previous node output (or trigger data for root) │
│                                                                  │
│  2. build_context(execution, node_results, input)                │
│     └─> Creates expression context:                              │
│         {                                                        │
│           "json": <input from step 1>,                           │
│           "nodes": { "NodeA": {...}, "NodeB": {...} },           │
│           "execution": { "id": "...", ... },                     │
│           "workflow": { "id": "...", ... }                       │
│         }                                                        │
│                                                                  │
│  3. resolve_config(node.config, context)                         │
│     └─> Evaluates ALL expressions in config                      │
│         "{{ json.value }}" → 42                                  │
│         "{{ nodes.AddNode.json }}" → 52                          │
│                                                                  │
│  4. executor.execute(resolved_config, input, execution)          │
│     └─> Config values are ALREADY resolved!                      │
│         Just read config["fieldName"] directly                   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Config Field Types

### 1. Data Input Fields
Fields that accept values OR expressions referencing upstream data.

```elixir
"value" => %{
  "title" => "Value",
  "description" => "A number or expression like {{ json.amount }}"
}
```

**In execute:**
```elixir
value = config["value"]  # Already resolved - could be 42, "hello", %{...}, etc.
```

### 2. Literal-Only Fields
Fields that should only accept fixed values (enums, flags, etc.)

```elixir
"operation" => %{
  "type" => "string",
  "enum" => ["add", "subtract", "multiply"],
  "description" => "Operation to perform"
}
```

### 3. Optional Fields
Use `Map.get/3` with defaults.

```elixir
timeout = Map.get(config, "timeout_ms", 30_000)
```

---

## Expression Reference for Users

| Expression | Resolves To |
|------------|-------------|
| `{{ json }}` | Previous node's full output (or trigger data for root) |
| `{{ json.field }}` | Specific field from previous node |
| `{{ json.nested.path }}` | Nested field access |
| `{{ nodes.NodeId.json }}` | Specific upstream node's output |
| `{{ nodes.NodeId.json.field }}` | Field from specific upstream node |
| `{{ execution.id }}` | Current execution ID |
| `{{ workflow.id }}` | Current workflow ID |

---

## Executor Template

```elixir
defmodule Fizz.Nodes.Executors.MyNode do
  @moduledoc """
  Brief description of what this node does.

  ## Configuration

  - `input_field` (required) - Description. Supports expressions.
  - `option_field` (optional) - Description. Default: X.

  ## Output

  Description of output shape.
  """

  use Fizz.Steps.Definition,
    id: "my_node",
    name: "My Node",
    category: "Category",
    description: "What it does",
    icon: "hero-icon-name",
    kind: :action | :transform | :trigger | :control_flow

  alias Fizz.Fields

  @fields [
    Fields.string("input_field",
      label: "Input Field",
      description: "The data to process. Use {{ json }} or {{ nodes.X.json }}",
      required?: true
    ),
    Fields.string("option_field",
      label: "Option",
      default: "default_value",
      description: "Optional setting"
    )
  ]

  @input_schema %{
    "description" => "Populates {{ json }} for expressions"
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "result" => %{"type" => "string"}
    }
  }

  @behaviour Fizz.Steps.Executor

  @impl true
  def execute(config, _input, _execution) do
    # 1. Extract config values (already expression-resolved)
    input_field = config["input_field"]
    option_field = Map.get(config, "option_field", "default_value")

    # 2. Validate/coerce if needed
    with {:ok, validated} <- validate_input(input_field) do
      # 3. Do the work
      result = process(validated, option_field)

      # 4. Return output
      {:ok, %{"result" => result}}
    end
  end

  @impl true
  def validate_config(config) do
    errors = []

    errors =
      if Map.get(config, "input_field") do
        errors
      else
        [{:input_field, "is required"} | errors]
      end

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  # Private helpers...
end
```

---

## Common Patterns

### Pattern 1: Single Data Input
Most transform/action nodes.

```elixir
@fields [
  Fields.string("value", label: "Value", description: "...", required?: true)
]

def execute(config, _input, _execution) do
  value = config["value"]
  {:ok, transform(value)}
end
```

### Pattern 2: Two Data Inputs
Comparison, math, merge operations.

```elixir
@fields [
  Fields.string("left", label: "Left Value", required?: true),
  Fields.string("right", label: "Right Value", required?: true)
]

def execute(config, _input, _execution) do
  left = config["left"]
  right = config["right"]
  {:ok, combine(left, right)}
end
```

### Pattern 3: Data + Options
Data to process plus configuration options.

```elixir
@fields [
  Fields.string("text", label: "Text", required?: true),
  Fields.select("case", label: "Case", options: Fields.options(~w(upper lower)))
]

def execute(config, _input, _execution) do
  text = config["text"] |> to_string()
  case_type = Map.get(config, "case", "upper")
  
  result = case case_type do
    "upper" -> String.upcase(text)
    "lower" -> String.downcase(text)
  end
  
  {:ok, result}
end
```

### Pattern 4: Passthrough with Side Effect
Logging, metrics, notifications.

```elixir
def execute(config, _input, _execution) do
  value = config["value"]
  
  # Side effect
  Logger.info("Debug: #{inspect(value)}")
  
  # Pass through unchanged
  {:ok, value}
end
```

---

## Type Coercion Helpers

Expressions can resolve to various types. Handle gracefully:

```elixir
defp to_number(n) when is_number(n), do: {:ok, n}
defp to_number(s) when is_binary(s) do
  case Float.parse(s) do
    {num, _} -> {:ok, num}
    :error -> {:error, "not a number: #{s}"}
  end
end
defp to_number(%{"value" => v}), do: to_number(v)  # Wrapped values
defp to_number(other), do: {:error, "expected number, got: #{inspect(other)}"}

defp to_string_safe(nil), do: ""
defp to_string_safe(s) when is_binary(s), do: s
defp to_string_safe(n) when is_number(n), do: Number.to_string(n)
defp to_string_safe(%{"value" => v}), do: to_string_safe(v)
defp to_string_safe(other), do: inspect(other)

defp to_list(l) when is_list(l), do: {:ok, l}
defp to_list(%{"value" => v}), do: to_list(v)
defp to_list(other), do: {:ok, [other]}  # Wrap single value

defp to_map(m) when is_map(m), do: {:ok, m}
defp to_map(_), do: {:error, "expected object"}
```

---

## Return Values

```elixir
# Success - return output data
{:ok, %{"result" => value, "metadata" => %{...}}}
{:ok, "simple string output"}
{:ok, 42}
{:ok, [1, 2, 3]}

# Failure - execution failed, workflow may stop
{:error, "Human readable error message"}
{:error, %{"code" => "TIMEOUT", "message" => "Request timed out"}}

# Skip - node didn't run but that's okay (conditional logic)
{:skip, "Condition not met"}
```

---

## Checklist for New Executors

- [ ] All data inputs are config fields (not read from `input` param)
- [ ] Field definitions have clear labels and descriptions
- [ ] Descriptions mention expression support where applicable
- [ ] Required fields use `required?: true`
- [ ] `validate_config/1` checks required fields and valid values
- [ ] Type coercion handles strings, numbers, wrapped values
- [ ] Error messages are human-readable
- [ ] Output shape is documented in `@output_schema`
- [ ] Module has `@moduledoc` explaining usage

---

---

## Exceptions: When Auto-Wiring Makes Sense

While explicit config fields are the default, some node types benefit from automatic input wiring. These are **exceptions** that should be used sparingly.

### Exception 1: Pure Passthrough Nodes

Nodes whose sole purpose is to pass data through unchanged (with optional side effects).

**Examples:** Debug/Log, Delay/Wait, Checkpoint

```elixir
defmodule Fizz.Nodes.Executors.Wait do
  # Config only has options, not data
  @fields [
    Fields.number("seconds", label: "Seconds", default: 5)
  ]

  def execute(config, input, _execution) do
    seconds = Map.get(config, "seconds", 5)
    :timer.sleep(trunc(seconds * 1000))
    
    # Pass through whatever came in - this is the point of the node
    {:ok, input}
  end
end
```

**Why it's okay:** The node's purpose IS to pass data through. Requiring `"value" => "{{ json }}"` adds verbosity without benefit.

### Exception 2: Identity Transform Nodes

Nodes that reshape/filter the incoming data as their primary function.

**Examples:** Pick Fields, Omit Fields, Flatten, Filter

```elixir
defmodule Fizz.Nodes.Executors.Pick do
  @fields [
    Fields.json("fields", label: "Fields", description: "Fields to keep from the input")
  ]

  def execute(config, input, _execution) when is_map(input) do
    fields = config["fields"] || []
    {:ok, Map.take(input, fields)}
  end
end
```

**Why it's okay:** The node operates on "the data flowing through" conceptually. The config specifies *how* to transform, not *what* to transform.

### Exception 3: Aggregation/Collection Nodes

Nodes that collect or aggregate from multiple runs or branches.

**Examples:** Batch Collector, Merge Branches, Accumulator

```elixir
defmodule Fizz.Nodes.Executors.Merge do
  # No data config - merges all parent outputs automatically
  @fields [
    Fields.select("strategy",
      label: "Strategy",
      default: "shallow",
      options: Fields.options(~w(shallow deep))
    )
  ]

  def execute(config, input, _execution) when is_map(input) do
    # input is already merged from multiple parents by runtime
    strategy = Map.get(config, "strategy", "shallow")
    {:ok, apply_merge_strategy(input, strategy)}
  end
end
```

**Why it's okay:** The node's purpose is to unify multiple inputs. Explicit references would defeat the purpose.

### Exception 4: Trigger/Entry Nodes

Nodes that receive external data (webhooks, schedules, manual triggers).

**Examples:** Webhook Trigger, Schedule Trigger, Manual Trigger

```elixir
defmodule Fizz.Nodes.Executors.WebhookTrigger do
  def execute(_config, input, _execution) do
    # input IS the webhook payload - that's the point
    {:ok, input}
  end
end
```

**Why it's okay:** These are root nodes; `input` contains the trigger payload which is their output.

---

## Decision Guide: Explicit vs Auto-Wire

```
Is this node a trigger/entry point?
  └─ YES → Auto-wire (input = trigger payload)
  └─ NO ↓

Is the node's purpose to pass data through unchanged?
  └─ YES → Auto-wire (passthrough pattern)
  └─ NO ↓

Does the node reshape/filter "the incoming data" generically?
  └─ YES → Auto-wire (identity transform)
  └─ NO ↓

Does the node combine/aggregate multiple parent outputs?
  └─ YES → Auto-wire (aggregation pattern)
  └─ NO ↓

Does the node need specific values to operate on?
  └─ YES → Explicit config fields (default case)
```

---

## Marking Auto-Wire Nodes

When a node uses auto-wiring, document it clearly:

```elixir
@moduledoc """
...

## Input Handling

This node uses **automatic input wiring**. The previous node's output
(or merged outputs from multiple parents) is used directly.

Configure *how* to process the data, not *which* data to process.
"""

@input_schema %{
  "description" => "Receives previous node output automatically"
}
```

---

## Anti-Patterns to Avoid

### ✗ Reading from input directly
```elixir
def execute(config, input, _exec) do
  value = input["field"]  # BAD
end
```

### ✗ Magic field extraction
```elixir
value = if config["field"], do: input[config["field"]], else: input  # BAD
```

### ✗ Assuming input structure
```elixir
def execute(_config, %{"data" => data}, _exec) do  # BAD - pattern match on input
```

### ✗ Ignoring expression-resolved types
```elixir
def execute(config, _input, _exec) do
  # BAD - assumes string, but expression might resolve to number
  String.upcase(config["text"])
end
```

### ✓ Correct approach
```elixir
def execute(config, _input, _exec) do
  text = config["text"] |> to_string_safe()  # Coerce safely
  {:ok, String.upcase(text)}
end
```
