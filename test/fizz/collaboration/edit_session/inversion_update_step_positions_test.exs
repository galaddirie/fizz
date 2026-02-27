defmodule Fizz.Collaboration.EditSession.InversionUpdateStepPositionsTest do
  use ExUnit.Case, async: true

  alias Fizz.Collaboration.EditorState
  alias Fizz.Collaboration.EditSession.Inversion
  alias Fizz.Workflows.WorkflowDraft
  alias Fizz.Workflows.Embeds.Step

  describe "compute_inverse/3 for :update_step_positions" do
    test "captures previous positions for all updated steps" do
      draft = base_draft()

      operation = %{
        type: :update_step_positions,
        payload: %{
          step_positions: %{
            "step_a" => %{x: 100, y: 200},
            "step_b" => %{x: 300, y: 400}
          }
        }
      }

      assert {:ok, [inverse]} = Inversion.compute_inverse(draft, %EditorState{}, operation)
      assert inverse.type == :update_step_positions

      assert inverse.payload == %{
               step_positions: %{
                 "step_a" => %{x: 10, y: 20},
                 "step_b" => %{x: 30, y: 40}
               }
             }
    end

    test "fails when payload includes unknown step ids" do
      draft = base_draft()

      operation = %{
        type: :update_step_positions,
        payload: %{step_positions: %{"missing_step" => %{x: 100, y: 200}}}
      }

      assert {:error, {:steps_not_found, missing_ids}} =
               Inversion.compute_inverse(draft, %EditorState{}, operation)

      assert "missing_step" in missing_ids
    end
  end

  defp base_draft do
    %WorkflowDraft{
      workflow_id: Ecto.UUID.generate(),
      steps: [
        step("step_a", %{x: 10, y: 20}),
        step("step_b", %{x: 30, y: 40})
      ],
      connections: [],
      groups: []
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
end
