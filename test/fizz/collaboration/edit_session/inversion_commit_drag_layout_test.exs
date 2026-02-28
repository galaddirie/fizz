defmodule Fizz.Collaboration.EditSession.InversionCommitDragLayoutTest do
  use ExUnit.Case, async: true

  alias Fizz.Collaboration.EditorState
  alias Fizz.Collaboration.EditSession.{Inversion, Operations}
  alias Fizz.Workflows.Embeds.{NodeGroup, Step}
  alias Fizz.Workflows.WorkflowDraft

  describe "compute_inverse/3 for :commit_drag_layout" do
    test "captures previous bounds, step positions, and memberships" do
      draft = base_draft()

      operation = %{
        type: :commit_drag_layout,
        payload: %{
          txn_id: "txn-inverse-1",
          base_seq: 21,
          groups: [
            %{group_id: "group_a", position: %{x: 130, y: 140, width: 420, height: 320}},
            %{group_id: "group_b", position: %{x: 560, y: 190, width: 260, height: 210}}
          ],
          step_positions: %{
            "step_a" => %{x: 40, y: 30},
            "step_c" => %{x: 55, y: 65}
          },
          group_id_by_step_id: %{
            "step_b" => nil,
            "step_c" => "group_b"
          }
        }
      }

      assert {:ok, [inverse]} = Inversion.compute_inverse(draft, %EditorState{}, operation)
      assert inverse.type == :commit_drag_layout
      assert inverse.payload.txn_id == "txn-inverse-1"
      assert inverse.payload.base_seq == 21

      assert inverse.payload.groups == [
               %{group_id: "group_a", position: %{x: 100, y: 100, width: 320, height: 240}},
               %{group_id: "group_b", position: %{x: 540, y: 160, width: 280, height: 220}}
             ]

      assert inverse.payload.step_positions == %{
               "step_a" => %{x: 60, y: 60},
               "step_c" => %{x: 860, y: 260}
             }

      assert inverse.payload.group_id_by_step_id == %{
               "step_b" => "group_a",
               "step_c" => nil
             }
    end

    test "inverse operation restores previous draft state" do
      draft = base_draft()
      operation = move_operation()

      assert {:ok, [inverse]} = Inversion.compute_inverse(draft, %EditorState{}, operation)
      assert {:ok, moved_draft} = Operations.apply(draft, operation)
      assert {:ok, restored_draft} = Operations.apply(moved_draft, inverse)

      assert snapshot(restored_draft) == snapshot(draft)
    end
  end

  defp move_operation do
    %{
      type: :commit_drag_layout,
      payload: %{
        txn_id: "txn-inverse-2",
        base_seq: 22,
        groups: [
          %{group_id: "group_a", position: %{x: 130, y: 140, width: 420, height: 320}},
          %{group_id: "group_b", position: %{x: 560, y: 190, width: 260, height: 210}}
        ],
        step_positions: %{
          "step_a" => %{x: 40, y: 30},
          "step_c" => %{x: 55, y: 65}
        },
        group_id_by_step_id: %{
          "step_b" => nil,
          "step_c" => "group_b"
        }
      }
    }
  end

  defp snapshot(%WorkflowDraft{} = draft) do
    %{
      groups:
        draft.groups
        |> List.wrap()
        |> Enum.map(fn group ->
          %{
            id: group.id,
            step_ids: group.step_ids,
            output_step_id: group.output_step_id,
            position: group.position
          }
        end),
      steps:
        draft.steps
        |> List.wrap()
        |> Enum.map(fn step ->
          %{id: step.id, position: step.position}
        end)
    }
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
        group("group_a", ["step_a", "step_b"], "step_a", %{
          x: 100,
          y: 100,
          width: 320,
          height: 240
        }),
        group("group_b", ["step_d"], "step_d", %{x: 540, y: 160, width: 280, height: 220})
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
end
