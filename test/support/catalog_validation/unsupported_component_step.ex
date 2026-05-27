defmodule Fizz.TestSupport.CatalogValidation.UnsupportedComponentStep do
  use Fizz.Steps.Definition,
    id: "unsupported_component_step",
    name: "Unsupported Component Step",
    category: "Test",
    description: "Invalid step using an unsupported field component.",
    icon: "hero-bolt",
    kind: :action

  @behaviour Fizz.Steps.Executor

  @fields [
    %Fizz.Fields.Definition{key: "value", type: :string, component: "bespoke"}
  ]

  @impl true
  def execute(_config, _input, _context), do: {:ok, %{}}
end
