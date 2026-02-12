defmodule Fizz.Steps.Executors.Condition do
  @moduledoc """
  Executor for Condition (If/Else) steps.

  Evaluates a condition expression and routes data accordingly.
  In Runic, this becomes a `Runic.rule` that only fires when the condition passes.

  ## Configuration

  - `condition` (required) - Liquid expression that evaluates to truthy/falsy.
    Supports the standard expression variables: `{{ json }}`, `{{ steps.X.json }}`, etc.

  ## Input

  Receives input from parent step(s). The input is available as `{{ json }}` in expressions.

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

  @input_schema %{
    "description" => "Any data - available as {{ json }} in the condition"
  }

  @output_schema %{
    "description" => "Input data, passed through if condition is true"
  }

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Runtime.Expression

  @impl true
  def execute(config, input, ctx) do
    condition_expr = Map.fetch!(config, "condition")

    # Build variables for expression evaluation
    vars = build_vars(input, ctx)

    case evaluate_condition(condition_expr, vars) do
      {:ok, true} ->
        # Condition passed - pass input through
        {:ok, input}

      {:ok, false} ->
        # Condition failed - skip this branch
        {:skip, :condition_false}

      {:error, reason} ->
        {:error, {:condition_evaluation_failed, reason}}
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
        # Validate the expression syntax
        case Expression.validate(expr) do
          :ok -> :ok
          {:error, _} = err -> err
        end

      _ ->
        {:error, [condition: "must be a string"]}
    end
  end

  @doc """
  Evaluates a condition expression and returns {:ok, boolean} or {:error, reason}.
  Exported for use by RunicAdapter when building rules.
  """
  @spec evaluate_condition(String.t(), map()) :: {:ok, boolean()} | {:error, term()}
  def evaluate_condition(expr, vars) do
    case Expression.evaluate_with_vars(expr, vars) do
      {:ok, result} ->
        {:ok, truthy?(result)}

      {:error, _} = err ->
        err
    end
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp build_vars(input, ctx) do
    step_outputs =
      case ctx do
        %{step_outputs: outputs} when is_map(outputs) ->
          Map.new(outputs, fn {k, v} -> {k, %{"json" => v}} end)

        _ ->
          %{}
      end

    %{
      "json" => input,
      "steps" => step_outputs,
      "variables" => Map.get(ctx, :variables, %{}),
      "metadata" => Map.get(ctx, :metadata, %{})
    }
  end

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
