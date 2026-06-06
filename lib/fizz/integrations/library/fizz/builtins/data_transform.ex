defmodule Fizz.Integrations.Library.Fizz.Builtins.DataTransform do
  use Fizz.Integrations.Steps.Definition,
    id: "data_transform",
    name: "Data Transform",
    category: "Transform",
    description: "Apply lightweight transformations to the input payload",
    icon: "hero-adjustments-horizontal",
    kind: :transform,
    integration: "fizz"

  @behaviour Fizz.Workflows.StepExecutor

  @impl true
  def execute(_config, input, _context) do
    {:ok, input}
  end
end
