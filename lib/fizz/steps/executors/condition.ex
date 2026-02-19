defmodule Fizz.Steps.Executors.Condition do
  @moduledoc """
  Executor for Condition (If/Else) steps.

  Routes data based on a pre-resolved condition value.
  In Runic, this becomes a `Runic.rule` that only fires when the condition passes.

  ## Configuration

  - `condition` (required) - Value that evaluates to truthy/falsy.
    This can be configured with expressions in the workflow editor and is resolved before execute/3 runs.

  ## Input

  Receives input from parent step(s).

  ## Output

  If condition is true: passes input through unchanged.
  If condition is false: in Runic models, the rule doesn't fire and the branch is skipped.

  ## Example

      # Condition: "{{ json.status }} == 'active'"
      # Input: %{"status" => "active", "data" => 123}
      # Output: %{"status" => "active", "data" => 123}  (if condition passes)
  """

  use Fizz.Steps.Definition,
    id: "condition",
    name: "If/Else",
    category: "Control Flow",
    description: "Branch workflow based on a condition",
    icon: "hero-arrows-right-left",
    kind: :control_flow

  @config_schema %{
    "type" => "object",
    "required" => ["condition"],
    "properties" => %{
      "condition" => %{
        "type" => "string",
        "title" => "Condition",
        "description" => "Expression that evaluates to true/false (e.g., {{ json.value }} > 10)"
      },
      "true_output" => %{
        "type" => "string",
        "title" => "True Output Name",
        "default" => "true",
        "description" => "Name for the 'true' output branch"
      },
      "false_output" => %{
        "type" => "string",
        "title" => "False Output Name",
        "default" => "false",
        "description" => "Name for the 'false' output branch"
      }
    }
  }

  @input_schema %{"description" => "Any data"}

  @output_schema %{
    "description" => "Input data, passed through if condition is true"
  }

  @behaviour Fizz.Steps.Executors.Behaviour

  @impl true
  def execute(config, input, _ctx) do
    condition = Map.fetch!(config, "condition")

    case truthy?(condition) do
      true -> {:ok, input}
      false -> {:skip, :condition_false}
    end
  end

  @impl true
  def validate_config(config) do
    case Map.get(config, "condition") do
      nil ->
        {:error, [condition: "is required"]}

      "" ->
        {:error, [condition: "cannot be empty"]}

      expr when is_binary(expr) ->
        case String.trim(expr) do
          "" -> {:error, [condition: "cannot be empty"]}
          _ -> :ok
        end

      _ ->
        {:error, [condition: "must be a string"]}
    end
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp truthy?("true"), do: true
  defp truthy?("false"), do: false
  defp truthy?(""), do: false
  defp truthy?("0"), do: false
  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(0), do: false
  defp truthy?(value) when is_float(value) and value == 0.0, do: false
  defp truthy?([]), do: false
  defp truthy?(%{} = map) when map_size(map) == 0, do: false
  defp truthy?(_), do: true
end
