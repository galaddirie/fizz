defmodule Fizz.Integrations.Fizz.Builtins.JsonParser do
  use Fizz.Integrations.StepDefinition,
    id: "json_parser",
    name: "JSON Parser",
    category: "Transform",
    description: "Parse JSON strings into structured data",
    icon: "hero-code-bracket",
    kind: :transform,
    integration: "fizz"

  @behaviour Fizz.Workflows.StepExecutor

  @impl true
  def execute(_config, input, _context) do
    case input do
      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, decoded} -> {:ok, decoded}
          _ -> {:error, :invalid_json}
        end

      _ ->
        {:ok, input}
    end
  end
end
