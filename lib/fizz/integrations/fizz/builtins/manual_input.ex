defmodule Fizz.Integrations.Fizz.Builtins.ManualInput do
  use Fizz.Integrations.StepDefinition,
    id: "manual_input",
    name: "Manual Input",
    category: "Triggers",
    description: "Starts a workflow with provided input data",
    icon: "hero-cursor-arrow-rays",
    kind: :trigger,
    integration: "fizz"

  alias Fizz.Fields

  @fields [
    Fields.json("input_schema",
      label: "Input Schema",
      description: "JSON Schema describing expected input data"
    ),
    Fields.json("test_data",
      label: "Test Data",
      description: "JSON payload used for editor test runs and partial runs"
    )
  ]

  @behaviour Fizz.Workflows.StepExecutor
  alias Fizz.Triggers.RegistrationSpec

  @impl true
  def registration_spec(config, _context) do
    {:ok,
     %RegistrationSpec{
       kind: :manual,
       params: %{"input_schema" => Map.get(config, "input_schema")}
     }}
  end

  @impl true
  def execute(_config, input, _context) do
    {:ok, input}
  end

  @impl true
  def normalize_event(_config, raw_event) when is_map(raw_event), do: {:ok, raw_event}

  @impl true
  def effective_output_schema(config) do
    Map.get(config, "input_schema") || @output_schema
  end
end
