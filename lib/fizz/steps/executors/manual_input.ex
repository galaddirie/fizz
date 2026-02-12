defmodule Fizz.Steps.Executors.ManualInput do
  use Fizz.Steps.Definition,
    id: "manual_input",
    name: "Manual Input",
    category: "Triggers",
    description: "Starts a workflow with provided input data",
    icon: "hero-cursor-arrow-rays",
    kind: :trigger

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "input_schema" => %{
        "type" => "object",
        "title" => "Input Schema",
        "description" => "JSON Schema describing expected input data"
      },
      "trigger_data" => %{
        "type" => "string",
        "title" => "Trigger Data (JSON)",
        "format" => "json",
        "default" => "{}"
      }
    }
  }

  @behaviour Fizz.Steps.Executors.Behaviour

  @impl true
  def execute(_config, input, _context) do
    {:ok, input}
  end

  @impl true
  def effective_output_schema(config) do
    Map.get(config, "input_schema") || @output_schema
  end
end
