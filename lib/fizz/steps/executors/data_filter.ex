defmodule Fizz.Steps.Executors.DataFilter do
  use Fizz.Steps.Definition,
    id: "data_filter",
    name: "Data Filter",
    category: "Transform",
    description: "Filter data by selected fields",
    icon: "hero-funnel",
    kind: :transform

  @behaviour Fizz.Steps.Executors.Behaviour

  @impl true
  def execute(config, input, _context) do
    fields = Map.get(config, "fields") || Map.get(config, :fields)

    result =
      if is_list(fields) and is_map(input) do
        Map.take(input, fields)
      else
        input
      end

    {:ok, result}
  end
end
