defmodule Fizz.Integrations.Fizz.Builtins.Splitter do
  @moduledoc """
  Executor for Splitter steps.

  Splits a collection into individual items for parallel processing.
  In Runic, this creates a `Runic.map` component that iterates over items.

  ## Configuration

  - `field` (optional) - Dot-path to the field containing the collection.
    If not specified, treats the entire input as the collection.

  ## Input

  Receives a map or list. If `field` is specified, extracts the collection
  from that field.

  ## Output

  When used with Runic's map, each item becomes a separate fact that flows
  to downstream steps.

  ## Example

      # Input: %{"items" => [1, 2, 3]}
      # Config: %{"field" => "items"}
      # Output: Each of 1, 2, 3 flows as separate facts
  """

  use Fizz.Integrations.StepDefinition,
    id: "splitter",
    name: "Split Items",
    category: "Data",
    description: "Split a list into individual items for parallel processing",
    icon: "hero-arrows-pointing-out",
    kind: :transform,
    integration: "fizz"

  alias Fizz.Fields

  @fields [
    Fields.string("field",
      label: "Source Field",
      description: "Dot-path to field containing the collection (optional)"
    )
  ]

  @input_schema %{
    "description" => "A map containing a collection, or the collection itself"
  }

  @output_schema %{
    "description" => "Each item from the collection as a separate output"
  }

  @behaviour Fizz.Workflows.StepExecutor

  @impl true
  def execute(config, input, _ctx) do
    field = Map.get(config, "field")

    items = extract_items(field, input)

    case items do
      list when is_list(list) ->
        {:ok, list}

      %Range{} = range ->
        {:ok, Enum.to_list(range)}

      map when is_map(map) ->
        # Convert map to list of {key, value} tuples
        {:ok, Map.to_list(map)}

      nil ->
        {:ok, []}

      other ->
        # Wrap single item in list
        {:ok, [other]}
    end
  end

  # Extract items based on what `field` evaluates to:
  # - String path: extract from input using dot notation (e.g., "data.items")
  # - Already a list/enumerable: use directly (e.g., from expression {{ json.arr }})
  # - Nil/empty: use input directly
  defp extract_items(nil, input), do: input
  defp extract_items("", input), do: input

  defp extract_items(field, input) when is_binary(field) do
    # String path - extract from input using dot notation
    get_nested(input, String.split(field, "."))
  end

  defp extract_items(field, _input) when is_list(field) do
    # Already evaluated to a list - use directly
    field
  end

  defp extract_items(%Range{} = range, _input) do
    # Already a range - use directly
    range
  end

  defp extract_items(field, _input) when is_map(field) do
    # Already a map - use directly
    field
  end

  defp extract_items(other, _input) do
    # Single value that was evaluated - wrap in list will happen in main function
    other
  end

  @impl true
  def validate_config(_config), do: :ok

  defp get_nested(data, []), do: data
  defp get_nested(data, [key | rest]) when is_map(data), do: get_nested(Map.get(data, key), rest)
  defp get_nested(_, _), do: nil
end
