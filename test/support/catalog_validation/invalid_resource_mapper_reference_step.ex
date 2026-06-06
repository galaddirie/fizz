defmodule Fizz.TestSupport.CatalogValidation.InvalidResourceMapperReferenceStep do
  use Fizz.Integrations.Steps.Definition,
    id: "invalid_resource_mapper_reference_step",
    name: "Invalid Resource Mapper Reference Step",
    category: "Test",
    description: "Invalid step using resource mapper references to missing fields.",
    icon: "hero-table-cells",
    kind: :action

  @behaviour Fizz.Workflows.StepExecutor

  @fields [
    %Fizz.Fields.Definition{
      key: "values",
      type: :resource_mapper,
      resource_mapper: %{
        "kind" => "test.row_values",
        "fields" => %{"primary_resource" => "missing_resource"}
      }
    }
  ]

  @impl true
  def execute(_config, _input, _context), do: {:ok, %{}}
end
