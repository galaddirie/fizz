defmodule Fizz.Workflows.Compiler.ConnectionPlanTest do
  use ExUnit.Case, async: true

  alias Fizz.Workflows.Compiler.ConnectionPlan

  describe "build/1" do
    test "emits only planned connections and dependency input indexes" do
      dependency_connection = connection("source", "agent", "main", "model")
      flow_connection = connection("entry", "agent", "main", "main")

      ir = %{
        steps: %{
          "entry" => step("entry"),
          "source" => step("source"),
          "agent" => dependency_target_step("agent")
        },
        connections: [dependency_connection, flow_connection]
      }

      assert {:ok, %{connection_plan: plan}} = ConnectionPlan.build(ir)

      assert Map.keys(plan) |> Enum.sort() == [:connections, :dependency_inputs_by_target]
      assert Map.has_key?(plan.connections, dependency_connection.id)
      assert Map.has_key?(plan.connections, flow_connection.id)

      assert plan.dependency_inputs_by_target == %{
               "agent" => %{"model" => [dependency_connection.id]}
             }
    end
  end

  defp step(id) do
    %{
      id: id,
      type_id: "debug",
      compiled_config: %{},
      input_schema: %{},
      output_schema: %{}
    }
  end

  defp dependency_target_step(id) do
    %{
      id: id,
      type_id: "agent",
      compiled_config: %{},
      input_schema: %{
        "properties" => %{
          "model" => %{"connection" => %{"kind" => "dependency", "handle" => "model"}}
        }
      },
      output_schema: %{}
    }
  end

  defp connection(source_step_id, target_step_id, source_output, target_input) do
    %{
      id: Ecto.UUID.generate(),
      source_step_id: source_step_id,
      source_output: source_output,
      target_step_id: target_step_id,
      target_input: target_input
    }
  end
end
