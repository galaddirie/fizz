defmodule Fizz.Steps.Executors.Aggregator do
  @moduledoc """
  Executor for Aggregator steps.

  Aggregates items from a split/parallel processing back into a single value.
  In Runic, this creates a `Runic.reduce` component.

  ## Configuration

  - `operation` (required) - One of:
    - `collect` - Collect all items into a list (default)
    - `sum` - Sum all numeric items
    - `count` - Count the number of items
    - `concat` - Concatenate string items
    - `first` - Take the first item
    - `last` - Take the last item
    - `min` - Find the minimum value
    - `max` - Find the maximum value

  ## Input

  Receives items one at a time from a preceding Splitter or map operation.

  ## Output

  The aggregated result based on the operation.

  ## Example

      # Operation: sum
      # Receives: 1, 2, 3, 4, 5
      # Output: 15
  """

  use Fizz.Steps.Definition,
    id: "aggregator",
    name: "Aggregate Items",
    category: "Data",
    description: "Aggregate items back into a single value",
    icon: "hero-arrows-pointing-in",
    kind: :transform

  @config_schema %{
    "type" => "object",
    "required" => ["operation"],
    "properties" => %{
      "operation" => %{
        "type" => "string",
        "title" => "Operation",
        "enum" => ["collect", "sum", "count", "concat", "first", "last", "min", "max"],
        "default" => "collect",
        "description" => "How to aggregate the items"
      }
    }
  }

  @input_schema %{
    "description" => "Items from a split operation"
  }

  @output_schema %{
    "description" => "The aggregated result"
  }

  @behaviour Fizz.Steps.Executors.Behaviour

  @supported_operations ~w(collect sum count concat first last min max)

  @impl true
  def execute(config, input, _ctx) do
    operation = Map.get(config, "operation", "collect")

    # When used as a Runic.reduce, input is a single item at a time
    # This execute is called for non-Runic usage or validation
    # For Runic, the adapter creates the reduce with proper init/reducer

    # Handle both single item and list inputs for flexibility
    items = if is_list(input), do: input, else: [input]

    result = aggregate(operation, items)
    {:ok, result}
  end

  @impl true
  def validate_config(config) do
    case Map.get(config, "operation") do
      nil ->
        {:error, [operation: "is required"]}

      op when op in @supported_operations ->
        :ok

      _ ->
        {:error, [operation: "must be one of: #{Enum.join(@supported_operations, ", ")}"]}
    end
  end

  @doc """
  Returns the initial accumulator for the given operation.
  Used by RunicAdapter when creating Runic.reduce.
  """
  def init_for_operation("collect"), do: []
  def init_for_operation("sum"), do: 0
  def init_for_operation("count"), do: 0
  def init_for_operation("concat"), do: ""
  def init_for_operation("first"), do: nil
  def init_for_operation("last"), do: nil
  def init_for_operation("min"), do: nil
  def init_for_operation("max"), do: nil
  def init_for_operation(_), do: []

  @doc """
  Returns the reducer function for the given operation.
  Used by RunicAdapter when creating Runic.reduce.
  """
  def reducer_for_operation("collect"), do: fn item, acc -> acc ++ [item] end
  def reducer_for_operation("sum"), do: fn item, acc -> acc + to_number(item) end
  def reducer_for_operation("count"), do: fn _item, acc -> acc + 1 end
  def reducer_for_operation("concat"), do: fn item, acc -> acc <> to_string(item) end

  def reducer_for_operation("first"),
    do: fn
      item, nil -> item
      _item, acc -> acc
    end

  def reducer_for_operation("last"), do: fn item, _acc -> item end

  def reducer_for_operation("min"),
    do: fn
      item, nil -> item
      item, acc -> min(item, acc)
    end

  def reducer_for_operation("max"),
    do: fn
      item, nil -> item
      item, acc -> max(item, acc)
    end

  def reducer_for_operation(_), do: fn item, acc -> acc ++ [item] end

  defp aggregate("collect", items), do: items
  defp aggregate("sum", items), do: Enum.reduce(items, 0, &(to_number(&1) + &2))
  defp aggregate("count", items), do: length(items)
  defp aggregate("concat", items), do: Enum.map_join(items, "", &to_string/1)
  defp aggregate("first", []), do: nil
  defp aggregate("first", [h | _]), do: h
  defp aggregate("last", []), do: nil
  defp aggregate("last", items), do: List.last(items)
  defp aggregate("min", []), do: nil
  defp aggregate("min", items), do: Enum.min(items)
  defp aggregate("max", []), do: nil
  defp aggregate("max", items), do: Enum.max(items)
  defp aggregate(_, items), do: items

  defp to_number(n) when is_number(n), do: n

  defp to_number(s) when is_binary(s) do
    case Float.parse(s) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp to_number(_), do: 0
end
