defmodule Fizz.Workflows.Contract do
  @moduledoc """
  Represents the derived input/output contract for a workflow draft.
  """

  alias Fizz.Workflows.WorkflowDraft
  alias Fizz.Steps.Executors.Behaviour, as: ExecutorBehaviour

  @type input_def :: %{
          name: String.t(),
          trigger_type: String.t(),
          trigger_step_id: String.t(),
          schema: map() | nil,
          description: String.t() | nil
        }

  @type output_def :: %{
          name: String.t(),
          output_step_id: String.t(),
          schema: map() | nil,
          description: String.t() | nil
        }

  @type t :: %__MODULE__{
          inputs: [input_def()],
          outputs: [output_def()]
        }

  @derive Jason.Encoder
  defstruct inputs: [], outputs: []

  @trigger_type_ids ["manual_input", "webhook_trigger", "schedule_trigger", "event_trigger"]
  @output_type_ids ["workflow_output", "data_output"]

  @doc """
  Derives the contract from a workflow draft.
  """
  @spec derive(WorkflowDraft.t()) :: t()
  def derive(%WorkflowDraft{} = draft) do
    steps = draft.steps || []

    inputs =
      steps
      |> Enum.filter(&trigger_step?/1)
      |> Enum.map(&input_from_trigger/1)

    outputs =
      steps
      |> Enum.filter(&output_step?/1)
      |> Enum.map(&output_from_step/1)

    %__MODULE__{inputs: inputs, outputs: outputs}
  end

  defp trigger_step?(%{type_id: type_id}), do: type_id in @trigger_type_ids
  defp output_step?(%{type_id: type_id}), do: type_id in @output_type_ids

  defp input_from_trigger(step) do
    schema = effective_output_schema(step.type_id, step.config || %{})

    %{
      name: step.name,
      trigger_type: step.type_id,
      trigger_step_id: step.id,
      schema: schema,
      description: step.notes
    }
  end

  defp output_from_step(step) do
    config = step.config || %{}

    %{
      name: Map.get(config, "name", "output"),
      output_step_id: step.id,
      schema: Map.get(config, "schema"),
      description: step.notes
    }
  end

  defp effective_output_schema(type_id, config) do
    case ExecutorBehaviour.resolve(type_id) do
      {:ok, executor} ->
        if function_exported?(executor, :effective_output_schema, 1) do
          executor.effective_output_schema(config)
        else
          registry_output_schema(type_id)
        end

      {:error, _reason} ->
        registry_output_schema(type_id)
    end
  end

  defp registry_output_schema(type_id) do
    case Fizz.Steps.Registry.get(type_id) do
      {:ok, type} -> type.output_schema
      {:error, :not_found} -> nil
    end
  end
end
