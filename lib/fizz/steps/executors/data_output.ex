defmodule Fizz.Steps.Executors.DataOutput do
  use Fizz.Steps.Definition,
    id: "data_output",
    name: "Data Output",
    category: "Output",
    description: "Emit the final output payload",
    icon: "hero-arrow-down-tray",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  @impl true
  def execute(_config, input, _context) do
    {:ok, input}
  end
end
