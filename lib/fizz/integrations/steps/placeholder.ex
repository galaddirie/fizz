defmodule Fizz.Integrations.Steps.Placeholder do
  @moduledoc """
  Shared execution shape for registered external steps without API clients yet.

  These steps are real catalog entries with fields and credential requirements,
  but their network implementation is intentionally pending.
  """

  defmacro __using__(_opts) do
    quote do
      @behaviour Fizz.Workflows.StepExecutor

      @impl true
      def execute(_config, _input, _ctx),
        do: Fizz.Integrations.Steps.Placeholder.not_implemented(__MODULE__)
    end
  end

  @spec not_implemented(module()) :: {:ok, map()}
  def not_implemented(module) when is_atom(module) do
    step_type = module.__step_definition__()

    {:ok,
     %{
       "status" => "not_implemented",
       "step_type_id" => step_type.id,
       "provider" => step_type.provider,
       "integration" => step_type.integration,
       "message" => "#{step_type.name} is registered but has no API implementation yet"
     }}
  end
end
