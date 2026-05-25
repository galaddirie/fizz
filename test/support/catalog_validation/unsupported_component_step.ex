defmodule Fizz.TestSupport.CatalogValidation.UnsupportedComponentStep do
  use Fizz.Steps.Definition,
    id: "unsupported_component_step",
    name: "Unsupported Component Step",
    category: "Test",
    description: "Invalid step using an unsupported field component.",
    icon: "hero-bolt",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "value" => %{"type" => "string", "ui" => %{"component" => "bespoke"}}
    }
  }

  @impl true
  def execute(_config, _input, _context), do: {:ok, %{}}
end
