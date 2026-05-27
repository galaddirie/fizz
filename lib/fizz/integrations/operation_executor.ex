defmodule Fizz.Integrations.OperationExecutor do
  @moduledoc """
  Generic workflow step executor for operation-backed integration steps.

  It resolves the operation definition from the step context and dispatches to
  the operation module with a typed `Fizz.Workflows.ExecutionContext`.
  """

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Catalog
  alias Fizz.Workflows.ExecutionContext

  @impl true
  def execute(config, input, context) when is_map(config) do
    context =
      context
      |> Map.put(:input, input)
      |> ExecutionContext.put_legacy_aliases()

    with {:ok, operation} <- operation_for(context) do
      operation.module.execute(config, input, context.execution_context)
    end
  end

  @impl true
  def validate_config(_config), do: :ok

  @impl true
  def default_config, do: %{}

  defp operation_for(context) do
    case context_value(context, :operation_id) do
      operation_id when is_binary(operation_id) ->
        with {:ok, operation} <- Catalog.operation(operation_id),
             :ok <- verify_step_type(operation, context_value(context, :type_id)) do
          {:ok, operation}
        else
          {:error, :not_found} -> {:error, {:operation_not_found, operation_id}}
          {:error, _reason} = error -> error
        end

      _operation_id ->
        operation_for_step_type(context)
    end
  end

  defp verify_step_type(_operation, nil), do: :ok

  defp verify_step_type(operation, step_type_id) when operation.step_type_id == step_type_id,
    do: :ok

  defp verify_step_type(operation, step_type_id) do
    {:error, {:operation_step_type_mismatch, operation.id, step_type_id}}
  end

  defp operation_for_step_type(context) do
    case context_value(context, :type_id) do
      type_id when is_binary(type_id) ->
        with {:ok, version} <- operation_version(context) do
          case version do
            nil -> Catalog.operation_for_step_type(type_id)
            version -> Catalog.operation_for_step_type(type_id, version)
          end
        end

      _type_id ->
        {:error, :operation_type_id_required}
    end
  end

  defp operation_version(context) do
    case context_value(context, :operation_version) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value when is_binary(value) -> parse_integer(value)
      nil -> {:ok, nil}
      value -> {:error, {:invalid_operation_version, value}}
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _invalid -> {:error, {:invalid_operation_version, value}}
    end
  end

  defp context_value(context, key) when is_map(context) and is_atom(key) do
    Map.get(context, key) || Map.get(context, Atom.to_string(key))
  end
end
