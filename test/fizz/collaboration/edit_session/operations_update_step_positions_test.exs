defmodule Fizz.Collaboration.EditSession.OperationsUpdateStepPositionsTest do
  use ExUnit.Case, async: true

  alias Fizz.Collaboration.EditSession.Operations
  alias Fizz.Workflows.WorkflowDraft
  alias Fizz.Workflows.Embeds.Step

  describe "validate/2 for :update_step_positions" do
    test "accepts known step ids" do
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

      assert :ok = Operations.validate(draft, operation)
    end

    test "rejects missing step ids" do
      draft = base_draft()

      operation = %{
        type: :update_step_positions,
        payload: %{step_positions: %{"missing_step" => %{x: 100, y: 200}}}
      }

      assert {:error, {:steps_not_found, missing_ids}} = Operations.validate(draft, operation)
      assert "missing_step" in missing_ids
    end
  end

  describe "apply/2 for :update_step_positions" do
    test "updates all provided step positions in one operation" do
      draft = base_draft()

      operation = %{
        type: :update_step_positions,
        payload: %{
          step_positions: %{
            "step_a" => %{x: 110, y: 210},
            "step_b" => %{x: 310, y: 410}
          }
        }
      }

      assert {:ok, updated_draft} = Operations.apply(draft, operation)
      assert position_for(updated_draft, "step_a") == %{x: 110, y: 210}
      assert position_for(updated_draft, "step_b") == %{x: 310, y: 410}
      assert position_for(updated_draft, "step_c") == %{x: 50, y: 60}
    end
  end

  defp base_draft do
    %WorkflowDraft{
      workflow_id: Ecto.UUID.generate(),
      steps: [
        step("step_a", %{x: 10, y: 20}),
        step("step_b", %{x: 30, y: 40}),
        step("step_c", %{x: 50, y: 60})
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

  defp position_for(%WorkflowDraft{} = draft, step_id) do
    draft.steps
    |> Enum.find(fn step -> step.id == step_id end)
    |> Map.get(:position)
  end
end
