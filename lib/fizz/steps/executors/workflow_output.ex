defmodule Fizz.Steps.Executors.WorkflowOutput do
  use Fizz.Steps.Definition,
    id: "workflow_output",
    name: "Workflow Output",
    category: "Output",
    description: "Declares the workflow's output with an optional schema",
    icon: "hero-arrow-right-end-on-rectangle",
    kind: :action

  require Logger

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "name" => %{
        "type" => "string",
        "title" => "Output Name",
        "default" => "output",
        "description" => "Identifier for this output (useful for multiple outputs)"
      },
      "schema" => %{
        "type" => "object",
        "title" => "Output Schema",
        "description" => "JSON Schema describing the output shape"
      },
      "value" => %{
        "title" => "Value",
        "description" => "The data to output. Defaults to the step's input if not specified."
      }
    }
  }

  @default_config %{"name" => "output"}

  @behaviour Fizz.Steps.Executors.Behaviour

  @impl true
  def execute(config, input, _context) do
    output =
      case Map.fetch(config, "value") do
        {:ok, value} -> value
        :error -> input
      end

    case validate_output(output, Map.get(config, "schema")) do
      :ok ->
        {:ok, output}

      {:error, errors} ->
        Logger.warning("Workflow output does not match declared schema", errors: errors)
        {:ok, output}
    end
  end

  defp validate_output(_output, nil), do: :ok

  defp validate_output(output, schema) do
    case JSV.build(schema) do
      {:ok, compiled} ->
        case JSV.validate(output, compiled) do
          {:ok, _} ->
            :ok

          {:error, error} ->
            {:error, JSV.normalize_error(error)}
        end

      {:error, error} ->
        {:error, %{message: Exception.message(error)}}
    end
  end
end
