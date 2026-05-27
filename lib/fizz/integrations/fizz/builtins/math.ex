defmodule Fizz.Integrations.Fizz.Builtins.Math do
  @moduledoc """
  Executor for Math steps.

  Performs arithmetic and mathematical operations on configured values.

  ## Configuration

  - `operation` (required) - One of: add, subtract, multiply, divide, modulo, power, square_root, abs, round, ceil, floor
  - `value` (required) - The left-hand value to operate on. Supports expressions like `{{ json.amount }}`.
  - `operand` (required for binary operations: add, subtract, multiply, divide, modulo, power) - The right-hand value. Supports expressions.
  """

  use Fizz.Integrations.StepDefinition,
    id: "math",
    name: "Math",
    category: "Data",
    description: "Perform arithmetic operations on numeric data",
    icon: "hero-calculator",
    kind: :transform,
    integration: "fizz"

  alias Fizz.Fields

  @supported_operations ~w(add subtract multiply divide modulo power square_root abs round ceil floor)

  @fields [
    Fields.select("operation",
      label: "Operation",
      required?: true,
      description: "The mathematical operation to perform",
      options: Fields.options(@supported_operations)
    ),
    Fields.number("value",
      label: "Value",
      required?: true,
      description: "The left-hand value to operate on (supports expressions)"
    ),
    Fields.number("operand",
      label: "Operand",
      description:
        "The right-hand value for binary operations (not needed for unary operations like square_root, abs, etc.)"
    )
  ]

  @input_schema %{
    "description" => "Populates {{ json }} for expressions"
  }

  @output_schema %{
    "type" => "number",
    "description" => "The result of the arithmetic operation"
  }

  @behaviour Fizz.Workflows.StepExecutor

  @impl true
  def execute(config, _input, _execution) do
    operation = Map.fetch!(config, "operation")
    value = Map.get(config, "value")
    operand = Map.get(config, "operand")

    unary_operations = ~w(square_root abs round ceil floor)

    if operation in unary_operations do
      # Unary operations only need the input value
      with {:ok, number} <- validate_number(value),
           {:ok, result} <- calculate(operation, number) do
        {:ok, result}
      else
        {:error, reason} -> {:error, reason}
      end
    else
      # Binary operations need both input value and operand
      with {:ok, number} <- validate_number(value),
           {:ok, operand_num} <- validate_number(operand),
           {:ok, result} <- calculate(operation, number, operand_num) do
        {:ok, result}
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def validate_config(config) do
    errors = []

    errors =
      case Map.get(config, "operation") do
        nil -> [{:operation, "is required"} | errors]
        op when op in @supported_operations -> errors
        _ -> [{:operation, "must be one of: #{Enum.join(@supported_operations, ", ")}"} | errors]
      end

    errors =
      case Map.get(config, "value") do
        nil ->
          [{:value, "is required"} | errors]

        value when is_binary(value) ->
          if expression_string?(value) do
            errors
          else
            case validate_number(value) do
              {:ok, _} -> errors
              {:error, _} -> [{:value, "must be a number"} | errors]
            end
          end

        value ->
          case validate_number(value) do
            {:ok, _} -> errors
            {:error, _} -> [{:value, "must be a number"} | errors]
          end
      end

    operation = Map.get(config, "operation")
    unary_operations = ~w(square_root abs round ceil floor)

    errors =
      if operation in unary_operations do
        # For unary operations, operand is not required
        errors
      else
        # For binary operations, operand is required
        case Map.get(config, "operand") do
          nil ->
            [{:operand, "is required for binary operations"} | errors]

          val when is_number(val) ->
            errors

          val when is_binary(val) ->
            if expression_string?(val) do
              errors
            else
              case Float.parse(val) do
                {_, ""} -> errors
                _ -> [{:operand, "must be a number"} | errors]
              end
            end

          _ ->
            [{:operand, "must be a number"} | errors]
        end
      end

    if errors == [] do
      :ok
    else
      {:error, Enum.reverse(errors)}
    end
  end

  # Binary operations
  defp calculate("add", a, b), do: {:ok, a + b}
  defp calculate("subtract", a, b), do: {:ok, a - b}
  defp calculate("multiply", a, b), do: {:ok, a * b}
  defp calculate("divide", _a, 0), do: {:error, "division by zero"}
  defp calculate("divide", a, b), do: {:ok, a / b}
  defp calculate("modulo", _a, b) when b == 0, do: {:error, "modulo by zero"}
  defp calculate("modulo", a, b), do: {:ok, rem(trunc(a), trunc(b))}
  defp calculate("power", a, b), do: {:ok, :math.pow(a, b)}

  # Unary operations
  defp calculate("square_root", a) when a < 0, do: {:error, "square root of negative number"}
  defp calculate("square_root", a), do: {:ok, :math.sqrt(a)}
  defp calculate("abs", a), do: {:ok, abs(a)}
  defp calculate("round", a), do: {:ok, round(a)}
  defp calculate("ceil", a), do: {:ok, Float.ceil(a)}
  defp calculate("floor", a), do: {:ok, Float.floor(a)}

  defp validate_number(n) when is_number(n), do: {:ok, n}

  defp validate_number(n) when is_binary(n) do
    case Float.parse(n) do
      {num, ""} -> {:ok, num}
      _ -> {:error, "invalid number: #{inspect(n)}"}
    end
  end

  defp validate_number(other), do: {:error, "expected a number, got: #{inspect(other)}"}

  defp expression_string?(value) when is_binary(value) do
    String.contains?(value, "{{") and String.contains?(value, "}}")
  end

  defp expression_string?(_value), do: false
end
