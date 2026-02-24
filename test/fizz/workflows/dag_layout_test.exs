defmodule Fizz.Workflows.DagLayoutTest do
  use ExUnit.Case, async: true
  alias Fizz.Workflows.DagLayout

  describe "compute/3 with subnodes" do
    test "positions subnodes vertically below their parent" do
      steps = [
        %{id: "agent", name: "Agent"},
        %{id: "model", name: "Model"},
        %{id: "prompt", name: "Prompt"}
      ]

      connections = [
        %{id: "c1", source_step_id: "model", target_step_id: "agent", target_input: "model"},
        %{id: "c2", source_step_id: "prompt", target_step_id: "agent", target_input: "prompt"}
      ]

      layout = DagLayout.compute(steps, connections)

      assert Map.has_key?(layout, "agent")
      assert Map.has_key?(layout, "model")
      assert Map.has_key?(layout, "prompt")

      agent_pos = layout["agent"]
      model_pos = layout["model"]
      prompt_pos = layout["prompt"]

      # Subnodes should be at the same X as parent (centered)
      assert model_pos.x == agent_pos.x
      assert prompt_pos.x == agent_pos.x

      # Subnodes should be below parent
      assert model_pos.y > agent_pos.y
      assert prompt_pos.y > agent_pos.y

      # Subnodes should be vertically stacked
      assert prompt_pos.y > model_pos.y
    end
  end

  describe "compute_edges/3 with subnodes" do
    test "generates paths from top to bottom for subnodes" do
      layout = %{
        "agent" => %{x: 100, y: 100, layer: 0, index: 0},
        "model" => %{x: 100, y: 250, layer: 1, index: 0, is_subnode: true}
      }

      connections = [
        %{id: "c1", source_step_id: "model", target_step_id: "agent", target_input: "model"}
      ]

      edges = DagLayout.compute_edges(connections, layout)
      assert length(edges) == 1
      edge = List.first(edges)

      # Subnode to Parent: Start from TOP of source (model), end at BOTTOM of target (agent)
      # model.y
      assert edge.y1 == 250
      # agent.y + step_height
      assert edge.y2 == 100 + 80
    end
  end
end
