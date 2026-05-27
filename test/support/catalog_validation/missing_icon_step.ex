defmodule Fizz.TestSupport.CatalogValidation.MissingIconStep do
  use Fizz.Integrations.StepDefinition,
    id: "missing_icon_step",
    name: "Missing Icon Step",
    category: "Test",
    description: "Invalid step missing an icon.",
    icon: "",
    kind: :action

  @behaviour Fizz.Workflows.StepExecutor

  @impl true
  def execute(_config, _input, _context), do: {:ok, %{}}
end
