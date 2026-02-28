defmodule Fizz.Collaboration.EditSession.OperationsAddStepGroupResizeTest do
  use ExUnit.Case, async: true

  alias Fizz.Collaboration.EditSession.Operations
  alias Fizz.Workflows.Embeds.{NodeGroup, Step}
  alias Fizz.Workflows.WorkflowDraft

  test "add_step into group expands group bounds when step overflows content area" do
    draft = base_draft()

    operation = %{
      type: :add_step,
      payload: %{
        step: %{
          id: "step_new",
          type_id: "math",
          name: "step_new",
          config: %{},
          position: %{x: 320, y: 200}
        },
        group_id: "group_a"
      }
    }

    assert :ok = Operations.validate(draft, operation)
    assert {:ok, updated_draft} = Operations.apply(draft, operation)

    assert group_step_ids_for(updated_draft, "group_a") == ["step_a", "step_new"]

    assert group_position_for(updated_draft, "group_a") == %{
             x: 100,
             y: 100,
             width: 494,
             height: 302
           }
  end

  test "add_step expansion uses provided step_size when present" do
    draft = base_draft()

    operation = %{
      type: :add_step,
      payload: %{
        step: %{
          id: "step_large",
          type_id: "math",
          name: "step_large",
          config: %{},
          position: %{x: 320, y: 200}
        },
        group_id: "group_a",
        step_size: %{width: 300, height: 100}
      }
    }

    assert :ok = Operations.validate(draft, operation)
    assert {:ok, updated_draft} = Operations.apply(draft, operation)

    assert group_position_for(updated_draft, "group_a") == %{
             x: 100,
             y: 100,
             width: 644,
             height: 352
           }
  end

  defp base_draft do
    %WorkflowDraft{
      workflow_id: Ecto.UUID.generate(),
      steps: [
        %Step{
          id: "step_a",
          type_id: "math",
          name: "step_a",
          config: %{},
          position: %{x: 40, y: 40}
        }
      ],
      connections: [],
      groups: [
        %NodeGroup{
          id: "group_a",
          name: "Group A",
          step_ids: ["step_a"],
          output_step_id: "step_a",
          position: %{x: 100, y: 100, width: 360, height: 240},
          color: nil,
          collapsed: false
        }
      ]
    }
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
end
