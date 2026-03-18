defmodule Fizz.Workflows.CompilerScenarioHelper do
  @moduledoc false

  alias Fizz.Workflows.Compiler
  alias Fizz.Workflows.Embeds.{Connection, Step}
  alias Fizz.Workflows.WorkflowDefinitionVersion
  alias Runic.Workflow

  def step(attrs) do
    %Step{
      id: Map.get(attrs, :id, Ecto.UUID.generate()),
      type_id: Map.fetch!(attrs, :type_id),
      name: Map.get(attrs, :name, attrs.type_id),
      config: Map.get(attrs, :config, %{}),
      position: Map.get(attrs, :position, %{}),
      notes: Map.get(attrs, :notes)
    }
  end

  def connection(attrs) do
    %Connection{
      id: Map.get(attrs, :id, Ecto.UUID.generate()),
      source_step_id: Map.fetch!(attrs, :source_step_id),
      source_output: Map.get(attrs, :source_output, "main"),
      target_step_id: Map.fetch!(attrs, :target_step_id),
      target_input: Map.get(attrs, :target_input, "main")
    }
  end

  def version(steps, connections) do
    %WorkflowDefinitionVersion{
      id: Ecto.UUID.generate(),
      steps: steps,
      connections: connections,
      step_groups: [],
      viewport: %{},
      settings: %{}
    }
  end

  def compile!(%WorkflowDefinitionVersion{} = version) do
    case Compiler.compile(version) do
      {:ok, workflow, compiled_hash} -> {workflow, compiled_hash}
      {:error, errors} -> raise "expected workflow to compile, got: #{inspect(errors)}"
    end
  end

  def react(%Workflow{} = workflow, input) do
    workflow
    |> Workflow.plan_eagerly(input)
    |> Workflow.react_until_satisfied()
  end

  def productions(%Workflow{} = workflow, step_id) do
    Workflow.raw_productions(workflow, step_id)
  end
end
