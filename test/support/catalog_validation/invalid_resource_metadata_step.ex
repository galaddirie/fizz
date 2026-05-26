defmodule Fizz.TestSupport.CatalogValidation.InvalidResourceMetadataStep do
  use Fizz.Steps.Definition,
    id: "invalid_resource_metadata_step",
    name: "Invalid Resource Metadata Step",
    category: "Test",
    description: "Invalid step using malformed resource metadata.",
    icon: "hero-table-cells",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "resource" => %{
        "type" => "string",
        "ui" => %{
          "component" => "resource_locator",
          "resource_locator" => "not a map"
        }
      }
    }
  }

  @impl true
  def execute(_config, _input, _context), do: {:ok, %{}}
end
