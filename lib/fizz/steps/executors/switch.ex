defmodule Fizz.Steps.Executors.Switch do
  @moduledoc """
  Executor for Switch steps.

  Routes data to different outputs based on matching a value against cases.
  Unlike Condition which is binary, Switch supports multiple branches.

  ## Configuration

  - `value` (required) - Expression to evaluate and match against cases.
  - `cases` (required) - List of case objects with `match` and `output` fields.
  - `default_output` (optional) - Output name when no case matches (default: "default")

  ## Input

  Receives input from parent step(s). Available as `{{ json }}` in expressions.

  ## Output

  Tagged output `{:branch, output_name, data}` indicating which branch matched.
  In Runic, this creates multiple rules, one per case.

  ## Example

      # Config:
      #   value: "{{ json.status }}"
      #   cases:
      #     - match: "pending", output: "pending"
      #     - match: "active", output: "active"
      #   default_output: "other"
      #
      # Input: %{"status" => "active"}
      # Output routes to "active" branch
  """

  use Fizz.Steps.Definition,
    id: "switch",
    name: "Switch",
    category: "Control Flow",
    description: "Route data based on matching value against cases",
    icon: "hero-list-bullet",
    kind: :control_flow

  @config_schema %{
    "type" => "object",
    "required" => ["value", "cases"],
    "properties" => %{
      "value" => %{
        "type" => "string",
        "title" => "Value Expression",
        "description" => "Expression to evaluate and match (e.g., {{ json.type }})"
      },
      "cases" => %{
        "type" => "array",
        "title" => "Cases",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "match" => %{
              "type" => "string",
              "title" => "Match Value"
            },
            "output" => %{
              "type" => "string",
              "title" => "Output Name"
            }
          }
        },
        "description" => "List of cases to match against"
      },
      "default_output" => %{
        "type" => "string",
        "title" => "Default Output",
        "default" => "default",
        "description" => "Output when no case matches"
      }
    }
  }

  @input_schema %{
    "description" => "Any data - the value field is extracted for matching"
  }

  @output_schema %{
    "description" => "Tagged tuple {:branch, output_name, input_data}"
  }

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Runtime.Expression

  @impl true
  def execute(config, input, ctx) do
    value_expr = Map.fetch!(config, "value")
    cases = Map.get(config, "cases", [])
    default_output = Map.get(config, "default_output", "default")

    # Evaluate the value expression
    vars = build_vars(input, ctx)

    case Expression.evaluate_with_vars(value_expr, vars) do
      {:ok, value} ->
        # Find matching case
        matched_case =
          Enum.find(cases, fn case_def ->
            match_value = Map.get(case_def, "match")
            normalize_for_match(value) == normalize_for_match(match_value)
          end)

        output =
          if matched_case do
            Map.get(matched_case, "output", "matched")
          else
            default_output
          end

        # Return tagged output for routing
        {:ok, {:branch, output, input}}

      {:error, reason} ->
        {:error, {:value_evaluation_failed, reason}}
    end
  end

  @impl true
  def validate_config(config) do
    errors = []

    errors =
      case Map.get(config, "value") do
        nil -> [{:value, "is required"} | errors]
        "" -> [{:value, "cannot be empty"} | errors]
        _ -> errors
      end

    errors =
      case Map.get(config, "cases") do
        nil -> [{:cases, "is required"} | errors]
        [] -> [{:cases, "must have at least one case"} | errors]
        cases when is_list(cases) -> validate_cases(cases, errors)
        _ -> [{:cases, "must be a list"} | errors]
      end

    if errors == [] do
      :ok
    else
      {:error, Enum.reverse(errors)}
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

  defp validate_cases(cases, errors) do
    Enum.reduce(cases, {errors, 0}, fn case_def, {errs, idx} ->
      new_errs =
        cond do
          not is_map(case_def) ->
            [{:"cases[#{idx}]", "must be an object"} | errs]

          not Map.has_key?(case_def, "match") ->
            [{:"cases[#{idx}].match", "is required"} | errs]

          not Map.has_key?(case_def, "output") ->
            [{:"cases[#{idx}].output", "is required"} | errs]

          true ->
            errs
        end

      {new_errs, idx + 1}
    end)
    |> elem(0)
  end

  defp normalize_for_match(value) when is_binary(value), do: String.trim(value)
  defp normalize_for_match(value) when is_number(value), do: to_string(value)
  defp normalize_for_match(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_for_match(value), do: value
end
