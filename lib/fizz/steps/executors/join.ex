defmodule Fizz.Steps.Executors.Join do
  @moduledoc """
  Executor for Join steps.

  Combines inputs from multiple parent branches into a single output.
  This step is automatically created when multiple branches converge,
  but can also be explicitly added to control join behavior.

  ## Configuration

  - `mode` (optional) - How to combine inputs from multiple branches:
    - `wait_all` - (default for non-fan-out) Wait for one value from each branch, output as list
    - `zip_nil` - (default for fan-out) Zip by index, pad shorter branches with `null`
    - `zip_shortest` - Zip by index, stop at shortest branch length
    - `zip_cycle` - Zip by index, cycle shorter branches to match longest
    - `cartesian` - Produce all combinations (use with caution on large inputs)

  - `flatten` (optional) - If true, flatten the output list one level (default: false)

  ## Input

  Receives a list of values from parent branches. In fan-out contexts, receives
  multiple items per branch.

  ## Output

  Depends on mode:
  - `wait_all`: Single list containing one value from each branch `[a, b, c]`
  - `zip_*`: List of tuples, one per index `[[a1, b1], [a2, b2], ...]`
  - `cartesian`: List of all combinations `[[a1, b1], [a1, b2], [a2, b1], ...]`

  ## Examples

  ### Wait All (default for simple merges)
  ```
  Branch A: "hello"
  Branch B: "world"
  Output: ["hello", "world"]
  ```

  ### Zip with Nil Padding (default for fan-out merges)
  ```
  Branch A (5 items): [1, 2, 3, 4, 5]
  Branch B (2 items): ["a", "b"]
  Output: [[1, "a"], [2, "b"], [3, nil], [4, nil], [5, nil]]
  ```

  ### Zip Shortest
  ```
  Branch A (5 items): [1, 2, 3, 4, 5]
  Branch B (2 items): ["a", "b"]
  Output: [[1, "a"], [2, "b"]]
  ```
  """

  use Fizz.Steps.Definition,
    id: "join",
    name: "Join",
    category: "Control Flow",
    description: "Combine inputs from multiple branches",
    icon: "hero-arrows-pointing-in",
    kind: :control_flow

  alias Fizz.Fields

  @supported_modes ~w(wait_all zip_nil zip_shortest zip_cycle cartesian)

  @fields [
    Fields.select("mode",
      label: "Join Mode",
      default: "zip_nil",
      description: "How to combine values from multiple branches",
      options: Fields.options(@supported_modes)
    ),
    Fields.boolean("flatten",
      label: "Flatten Output",
      default: false,
      description: "Flatten the output list one level"
    )
  ]

  @input_schema %{
    "type" => "array",
    "description" => "Values from parent branches"
  }

  @output_schema %{
    "description" => "Combined values according to join mode"
  }

  @behaviour Fizz.Steps.Executor

  @impl true
  def execute(config, input, _ctx) do
    mode = Map.get(config, "mode", "zip_nil") |> String.to_existing_atom()
    flatten? = Map.get(config, "flatten", false)

    # Input from a join is a list of values from parent branches
    # Each element corresponds to one parent branch's output
    branch_values = normalize_input(input)

    result = apply_join_mode(mode, branch_values)

    result =
      if flatten? do
        List.flatten(result)
      else
        result
      end

    {:ok, result}
  end

  @impl true
  def validate_config(config) do
    mode = Map.get(config, "mode", "zip_nil")

    if mode in @supported_modes do
      :ok
    else
      {:error, [mode: "must be one of: #{Enum.join(@supported_modes, ", ")}"]}
    end
  end

  # Normalize input to ensure it's a list of branch values
  defp normalize_input(input) when is_list(input) do
    # Check if this is already a list of branch values or a single list
    # If all elements are lists, treat as branch values; otherwise wrap
    if Enum.all?(input, &is_list/1) do
      input
    else
      [input]
    end
  end

  defp normalize_input(input) do
    [[input]]
  end

  # Apply join mode - delegates to Runic.Workflow.Join for consistency
  defp apply_join_mode(:wait_all, branch_values) do
    # For wait_all, just flatten one level
    List.flatten(branch_values, [])
  end

  defp apply_join_mode(:zip_nil, branch_values) do
    max_len = branch_values |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    if max_len == 0 do
      []
    else
      padded =
        Enum.map(branch_values, fn values ->
          values ++ List.duplicate(nil, max_len - length(values))
        end)

      0..(max_len - 1)
      |> Enum.map(fn i ->
        Enum.map(padded, &Enum.at(&1, i))
      end)
    end
  end

  defp apply_join_mode(:zip_shortest, branch_values) do
    min_len = branch_values |> Enum.map(&length/1) |> Enum.min(fn -> 0 end)

    if min_len == 0 do
      []
    else
      0..(min_len - 1)
      |> Enum.map(fn i ->
        Enum.map(branch_values, &Enum.at(&1, i))
      end)
    end
  end

  defp apply_join_mode(:zip_cycle, branch_values) do
    max_len = branch_values |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    if max_len == 0 do
      []
    else
      0..(max_len - 1)
      |> Enum.map(fn i ->
        Enum.map(branch_values, fn values ->
          if length(values) == 0 do
            nil
          else
            Enum.at(values, rem(i, length(values)))
          end
        end)
      end)
    end
  end

  defp apply_join_mode(:cartesian, branch_values) do
    case branch_values do
      [] ->
        []

      [single] ->
        Enum.map(single, &[&1])

      [first | rest] ->
        rest_cartesian = apply_join_mode(:cartesian, rest)

        for a <- first, b <- rest_cartesian do
          [a | b]
        end
    end
  end
end
