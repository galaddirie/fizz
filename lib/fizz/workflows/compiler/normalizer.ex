defmodule Fizz.Workflows.Compiler.Normalizer do
  @moduledoc false

  alias Fizz.Graph
  alias Fizz.Integrations.Steps.Registry, as: StepRegistry
  alias Fizz.Integrations.Steps.Type, as: StepType
  alias Fizz.Workflows.WorkflowDefinitionVersion

  @spec normalize(WorkflowDefinitionVersion.t()) :: {:ok, map()} | {:error, [map()]}
  def normalize(%WorkflowDefinitionVersion{} = version) do
    with {:ok, steps} <- normalize_steps(version.steps),
         {:ok, connections} <- normalize_connections(version.connections),
         :ok <- validate_trigger_roots(steps, connections),
         {:ok, topo_order} <- topological_order(version.steps, version.connections) do
      {:ok,
       %{
         definition_version_id: version.id,
         compiler_version: Fizz.Workflows.Compiler.compiler_version(),
         steps: steps,
         connections: connections,
         topo_order: topo_order
       }}
    end
  end

  defp normalize_steps(steps) do
    steps
    |> Enum.reduce_while({:ok, %{}}, fn step, {:ok, acc} ->
      with {:ok, type} <- StepRegistry.get(step.type_id),
           {:ok, executor} <- StepType.executor_module(type) do
        normalized_step = %{
          id: step.id,
          type_id: step.type_id,
          name: step.name,
          config: step.config,
          executor: executor,
          step_kind: type.step_kind,
          node_role: type.node_role,
          config_schema: type.config_schema,
          subnode_inputs: type.subnode_inputs,
          retry: type.retry
        }

        {:cont, {:ok, Map.put(acc, step.id, normalized_step)}}
      else
        {:error, :not_found} ->
          {:halt, {:error, [%{message: "unknown step type `#{step.type_id}`", step_id: step.id}]}}

        {:error, reason} ->
          {:halt,
           {:error,
            [
              %{
                message: "failed to resolve executor for `#{step.type_id}`: #{inspect(reason)}",
                step_id: step.id
              }
            ]}}
      end
    end)
  end

  defp normalize_connections(connections) do
    {:ok,
     Enum.map(connections, fn connection ->
       %{
         id: connection.id,
         source_step_id: connection.source_step_id,
         source_output: connection.source_output || "main",
         target_step_id: connection.target_step_id,
         target_input: connection.target_input || "main"
       }
     end)}
  end

  defp topological_order(steps, connections) do
    case Graph.from_workflow(steps, connections) do
      {:ok, graph} ->
        case Graph.topological_sort(graph) do
          {:ok, topo_order} ->
            {:ok, topo_order}

          {:error, {:cycle_detected, step_ids}} ->
            {:error, [%{message: "graph contains a cycle: #{Enum.join(step_ids, ", ")}"}]}
        end

      {:error, {:invalid_edges, invalid_edges}} ->
        {:error,
         [
           %{
             message:
               "graph contains invalid edges: #{Enum.map_join(invalid_edges, ", ", fn {source, target} -> "#{source}->#{target}" end)}"
           }
         ]}
    end
  end

  defp validate_trigger_roots(steps, connections) do
    incoming_step_ids =
      connections
      |> Enum.map(& &1.target_step_id)
      |> MapSet.new()

    errors =
      steps
      |> Map.values()
      |> Enum.filter(&(&1.step_kind == :trigger and MapSet.member?(incoming_step_ids, &1.id)))
      |> Enum.map(fn step ->
        %{
          step_id: step.id,
          message: "trigger steps must be graph roots with no incoming connections"
        }
      end)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end
end
