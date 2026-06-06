defmodule Fizz.Workflows.StepExecutor do
  @moduledoc """
  Behaviour and helpers for executable workflow step modules.
  """

  @doc """
  Executes the step with the given configuration, input, and runtime context.
  """
  @callback execute(config :: map(), input :: term(), context :: map()) ::
              {:ok, output :: term()}
              | {:error, reason :: term()}
              | {:skip, reason :: term()}

  @doc """
  Validates the step's configuration.
  """
  @callback validate_config(config :: map()) :: :ok | {:error, errors :: list()}

  @doc """
  Returns the default configuration for this step type.
  """
  @callback default_config() :: map()

  @doc """
  Returns the effective output schema for a step configuration.
  """
  @callback effective_output_schema(config :: map()) :: map() | nil

  @optional_callbacks validate_config: 1, default_config: 0, effective_output_schema: 1

  @doc """
  Resolves the executor module for a given step type ID.
  """
  def resolve(type_id) when is_binary(type_id) do
    case Fizz.Integrations.Steps.Registry.get(type_id) do
      {:ok, type} ->
        Fizz.Integrations.Steps.Type.executor_module(type)

      {:error, :not_found} ->
        {:error, {:not_found, type_id}}
    end
  end

  @doc """
  Resolves the executor module or raises.
  """
  def resolve!(type_id) do
    case resolve(type_id) do
      {:ok, module} -> module
      {:error, reason} -> raise "Failed to resolve executor for #{type_id}: #{inspect(reason)}"
    end
  end

  @doc """
  Executes a step using its type ID to resolve the executor.
  """
  def execute(type_id, config, input, context) do
    case resolve(type_id) do
      {:ok, module} ->
        module.execute(config, input, Map.put(context, :type_id, type_id))

      {:error, reason} ->
        {:error, {:executor_not_found, reason}}
    end
  end

  @doc """
  Validates config using the executor's validate_config callback if defined.
  """
  def validate_config(type_id, config) do
    case resolve(type_id) do
      {:ok, module} ->
        if function_exported?(module, :validate_config, 1) do
          module.validate_config(config)
        else
          :ok
        end

      {:error, _reason} ->
        :ok
    end
  end
end
