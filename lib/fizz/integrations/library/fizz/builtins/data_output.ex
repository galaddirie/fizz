defmodule Fizz.Integrations.Library.Fizz.Builtins.DataOutput do
  use Fizz.Integrations.Steps.Definition,
    id: "data_output",
    name: "Data Output",
    category: "Output",
    description: "Emit the final output payload",
    icon: "hero-arrow-down-tray",
    kind: :action,
    integration: "fizz"

  @behaviour Fizz.Workflows.StepExecutor

  @impl true
  def execute(_config, input, _context) do
    {:ok, input}
  end
end
