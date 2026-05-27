defmodule Fizz.IntegrationStepCase do
  @moduledoc """
  Test helpers for provider-owned step definitions and skeleton executors.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Fizz.IntegrationStepCase

      alias Fizz.Integrations.StepType
    end
  end

  alias Fizz.Integrations.StepRegistry, as: Registry
  alias Fizz.Integrations.StepType

  @spec step_type!(String.t()) :: StepType.t()
  def step_type!(step_type_id) when is_binary(step_type_id) do
    case Registry.get(step_type_id) do
      {:ok, %StepType{} = step_type} ->
        step_type

      {:error, :not_found} ->
        raise ArgumentError, "unknown step type #{inspect(step_type_id)}"
    end
  end

  @spec execute_step(String.t(), map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def execute_step(step_type_id, config \\ %{}, input \\ %{}, context \\ %{}) do
    step_type = step_type!(step_type_id)
    {:ok, module} = StepType.executor_module(step_type)

    module.execute(config, input, context)
  end

  @spec field!(StepType.t(), String.t()) :: Fizz.Fields.Definition.t()
  def field!(%StepType{} = step_type, key) when is_binary(key) do
    Enum.find(step_type.fields, fn field -> field.key == key end) ||
      raise ArgumentError, "step #{step_type.id} does not define field #{inspect(key)}"
  end

  @spec schema_property!(StepType.t(), String.t()) :: map()
  def schema_property!(%StepType{} = step_type, key) when is_binary(key) do
    step_type.config_schema
    |> Map.fetch!("properties")
    |> Map.fetch!(key)
  end
end
