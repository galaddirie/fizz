defmodule Fizz.Collaboration.EditSession.OperationsCommitDragLayoutTest do
  use ExUnit.Case, async: true

  alias Fizz.Collaboration.EditSession.Operations
  alias Fizz.Workflows.Embeds.{NodeGroup, Step}
  alias Fizz.Workflows.WorkflowDraft

  describe "apply/2 for :commit_drag_layout" do
    test "persists expanded group bounds from drop commit" do
      draft = base_draft()

      operation = %{
        type: :commit_drag_layout,
        payload: %{
          txn_id: "txn-expand-1",
          base_seq: 3,
          groups: [
            %{
              group_id: "group_a",
              position: %{x: 120, y: 140, width: 460, height: 320}
            }
          ],
          step_positions: %{},
          group_id_by_step_id: %{}
        }
      }

      assert :ok = Operations.validate(draft, operation)
      assert {:ok, updated_draft} = Operations.apply(draft, operation)

      assert group_position_for(updated_draft, "group_a") == %{
               x: 120,
               y: 140,
               width: 460,
               height: 320
             }
    end

    test "keeps child absolute positions stable when group origin shifts" do
      draft = base_draft()

      before_absolute =
        %{
          "step_a" => absolute_position_for(draft, "step_a"),
          "step_b" => absolute_position_for(draft, "step_b"),
          "step_c" => absolute_position_for(draft, "step_c")
        }

      operation = %{
        type: :commit_drag_layout,
        payload: %{
          txn_id: "txn-origin-shift-1",
          base_seq: 10,
          groups: [
            %{
              group_id: "group_a",
              position: %{x: 80, y: 90, width: 360, height: 260}
            }
          ],
          step_positions: %{
            "step_a" => %{x: 80, y: 70}
          },
          group_id_by_step_id: %{}
        }
      }

      assert :ok = Operations.validate(draft, operation)
      assert {:ok, updated_draft} = Operations.apply(draft, operation)

      assert absolute_position_for(updated_draft, "step_a") == before_absolute["step_a"]
      assert absolute_position_for(updated_draft, "step_b") == before_absolute["step_b"]
      assert absolute_position_for(updated_draft, "step_c") == before_absolute["step_c"]
    end

    test "applies memberships, bounds, and positions coherently in one operation" do
      draft = base_draft()

      operation = %{
        type: :commit_drag_layout,
        payload: %{
          txn_id: "txn-coherent-1",
          base_seq: 14,
          groups: [
            %{
              group_id: "group_a",
              position: %{x: 95, y: 105, width: 380, height: 280}
            },
            %{
              group_id: "group_b",
              position: %{x: 520, y: 120, width: 300, height: 220}
            }
          ],
          step_positions: %{
            "step_b" => %{x: 10, y: 15},
            "step_c" => %{x: 65, y: 75}
          },
          group_id_by_step_id: %{
            "step_b" => nil,
            "step_c" => "group_a"
          }
        }
      }

      assert :ok = Operations.validate(draft, operation)
      assert {:ok, updated_draft} = Operations.apply(draft, operation)

      assert group_position_for(updated_draft, "group_a") == %{
               x: 95,
               y: 105,
               width: 380,
               height: 280
             }

      assert group_position_for(updated_draft, "group_b") == %{
               x: 520,
               y: 120,
               width: 300,
               height: 220
             }

      assert position_for(updated_draft, "step_b") == %{x: 10, y: 15}
      assert position_for(updated_draft, "step_c") == %{x: 65, y: 75}

      assert group_step_ids_for(updated_draft, "group_a") |> Enum.sort() == ["step_a", "step_c"]
      assert group_step_ids_for(updated_draft, "group_b") == ["step_d"]
      assert group_output_step_for(updated_draft, "group_b") == "step_d"
    end
  end

  defp base_draft do
    %WorkflowDraft{
      workflow_id: Ecto.UUID.generate(),
      steps: [
        step("step_a", %{x: 60, y: 60}),
        step("step_b", %{x: 140, y: 110}),
        step("step_c", %{x: 860, y: 260}),
        step("step_d", %{x: 50, y: 70})
      ],
      connections: [],
      groups: [
        group("group_a", ["step_a"], "step_a", %{x: 100, y: 100, width: 320, height: 240}),
        group("group_b", ["step_b", "step_d"], "step_b", %{
          x: 500,
          y: 100,
          width: 280,
          height: 220
        })
      ]
    }
  end

  defp step(id, position) do
    %Step{
      id: id,
      type_id: "math",
      name: id,
      config: %{},
      position: position
    }
  end

  defp group(id, step_ids, output_step_id, position) do
    %NodeGroup{
      id: id,
      name: id,
      step_ids: step_ids,
      output_step_id: output_step_id,
      position: position,
      color: nil,
      collapsed: false
    }
  end

  defp position_for(%WorkflowDraft{} = draft, step_id) do
    draft.steps
    |> Enum.find(fn step -> step.id == step_id end)
    |> Map.get(:position)
  end

  defp group_position_for(%WorkflowDraft{} = draft, group_id) do
    draft.groups
    |> List.wrap()
    |> Enum.find(fn group -> group.id == group_id end)
    |> Map.get(:position)
  end

  defp group_step_ids_for(%WorkflowDraft{} = draft, group_id) do
    draft.groups
    |> List.wrap()
    |> Enum.find(fn group -> group.id == group_id end)
    |> Map.get(:step_ids)
  end

  defp group_output_step_for(%WorkflowDraft{} = draft, group_id) do
    draft.groups
    |> List.wrap()
    |> Enum.find(fn group -> group.id == group_id end)
    |> Map.get(:output_step_id)
  end

  defp absolute_position_for(%WorkflowDraft{} = draft, step_id) do
    step_position = position_for(draft, step_id)

    case find_group_for_step(draft, step_id) do
      nil ->
        step_position

      group ->
        group_position = Map.get(group, :position) || %{}

        %{
          x: (Map.get(group_position, :x) || 0) + (Map.get(step_position, :x) || 0),
          y: (Map.get(group_position, :y) || 0) + (Map.get(step_position, :y) || 0)
        }
    end
  end

  defp find_group_for_step(%WorkflowDraft{} = draft, step_id) do
    draft.groups
    |> List.wrap()
    |> Enum.find(fn group ->
      step_id in (Map.get(group, :step_ids) || [])
    end)
  end
end
