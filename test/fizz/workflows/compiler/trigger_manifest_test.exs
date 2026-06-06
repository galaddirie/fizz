defmodule Fizz.Workflows.Compiler.TriggerManifestTest do
  use ExUnit.Case, async: true

  alias Fizz.Workflows.Compiler
  alias Fizz.Workflows.WorkflowDefinitionVersion
  alias Fizz.Workflows.Embeds.{Connection, Step}

  test "compiler extracts trigger_manifest for workflows with trigger steps" do
    version = trigger_manifest_version()

    assert {:ok, workflow, _compiled_hash} = Compiler.compile(version)

    assert workflow.fizz_metadata.trigger_manifest == [
             %{
               step_id: hd(version.steps).id,
               type_id: "manual_input",
               config: %{}
             },
             %{
               step_id: List.last(version.steps).id,
               type_id: "schedule_trigger",
               config: %{"interval_seconds" => 60}
             }
           ]
  end

  test "compiler rejects trigger steps with incoming connections" do
    version = invalid_trigger_root_version()

    assert {:error, [%{step_id: step_id, message: message}]} = Compiler.compile(version)
    assert step_id == List.last(version.steps).id
    assert message == "trigger steps must be graph roots with no incoming connections"
  end

  test "trigger manifest includes step_id, type_id, and config" do
    version = trigger_manifest_version()

    assert {:ok, workflow, _compiled_hash} = Compiler.compile(version)

    assert Enum.all?(workflow.fizz_metadata.trigger_manifest, fn entry ->
             Map.has_key?(entry, :step_id) and
               Map.has_key?(entry, :type_id) and
               Map.has_key?(entry, :config)
           end)
  end

  defp trigger_manifest_version do
    manual_id = "00000000-0000-0000-0000-000000000001"
    schedule_id = "00000000-0000-0000-0000-000000000002"

    %WorkflowDefinitionVersion{
      id: Ecto.UUID.generate(),
      steps: [
        %Step{
          id: manual_id,
          type_id: "manual_input",
          name: "Manual",
          config: %{},
          position: %{},
          notes: nil
        },
        %Step{
          id: schedule_id,
          type_id: "schedule_trigger",
          name: "Schedule",
          config: %{"interval_seconds" => 60},
          position: %{},
          notes: nil
        }
      ],
      connections: [],
      step_groups: [],
      viewport: %{},
      settings: %{}
    }
  end

  defp invalid_trigger_root_version do
    manual_id = "00000000-0000-0000-0000-000000000011"
    schedule_id = "00000000-0000-0000-0000-000000000012"

    %WorkflowDefinitionVersion{
      id: Ecto.UUID.generate(),
      steps: [
        %Step{
          id: manual_id,
          type_id: "manual_input",
          name: "Manual",
          config: %{},
          position: %{},
          notes: nil
        },
        %Step{
          id: schedule_id,
          type_id: "schedule_trigger",
          name: "Schedule",
          config: %{"interval_seconds" => 60},
          position: %{},
          notes: nil
        }
      ],
      connections: [
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: manual_id,
          source_output: "main",
          target_step_id: schedule_id,
          target_input: "main"
        }
      ],
      step_groups: [],
      viewport: %{},
      settings: %{}
    }
  end
end
