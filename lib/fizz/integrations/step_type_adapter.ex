defmodule Fizz.Integrations.StepTypeAdapter do
  @moduledoc """
  Adapters between integration operation definitions and workflow step types.
  """

  alias Fizz.Integrations.OperationDefinition
  alias Fizz.Steps.Type

  @spec from_executor_module!(module()) :: Type.t()
  def from_executor_module!(module) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :__step_definition__, 0),
         %Type{} = type <- module.__step_definition__() do
      type
    else
      _ -> raise ArgumentError, "#{inspect(module)} must expose a step definition"
    end
  end

  @spec from_operation_definition!(OperationDefinition.t(), keyword()) :: Type.t()
  def from_operation_definition!(%OperationDefinition{} = operation, opts \\ []) do
    executor = Keyword.fetch!(opts, :executor)

    %Type{
      id: operation.step_type_id,
      name: display_value(operation.display, :name),
      category: display_value(operation.display, :category, "Integrations"),
      description: display_value(operation.display, :description, ""),
      icon: display_value(operation.display, :icon),
      executor: Atom.to_string(executor),
      step_kind: Keyword.get(opts, :kind, operation.kind || :action),
      default_config: operation.default_config,
      config_schema: operation.config_schema,
      input_schema: Keyword.get(opts, :input_schema, operation.input_schema),
      output_schema: operation.output_schema,
      subnode_inputs: Keyword.get(opts, :subnode_inputs, [])
    }
  end

  defp display_value(display, key, default \\ nil)

  defp display_value(display, key, default) when is_map(display) do
    Map.get(display, key) || Map.get(display, Atom.to_string(key)) || default
  end
end
