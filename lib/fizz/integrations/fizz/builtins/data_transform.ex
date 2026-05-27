defmodule Fizz.Integrations.Fizz.Builtins.DataTransform do
  use Fizz.Integrations.StepDefinition,
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
