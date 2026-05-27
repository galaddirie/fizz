defmodule Fizz.TestSupport.CatalogValidation.InvalidResourceMetadataStep do
  use Fizz.Integrations.Steps.Definition,
    id: "invalid_resource_metadata_step",
    name: "Invalid Resource Metadata Step",
    category: "Test",
    description: "Invalid step using malformed resource metadata.",
    icon: "hero-table-cells",
    kind: :action

  @behaviour Fizz.Workflows.StepExecutor

  @fields [
    %Fizz.Fields.Definition{
      key: "resource",
      type: :resource_locator,
      resource_locator: "not a map"
    }
  ]

  @impl true
  def execute(_config, _input, _context), do: {:ok, %{}}
end
