defmodule Fizz.Collaboration.EditSession.OperationsSubnodesTest do
  use ExUnit.Case, async: true

  alias Fizz.Collaboration.EditSession.Operations
  alias Fizz.Workflows.WorkflowDraft
  alias Fizz.Workflows.Embeds.{Connection, Step}

  describe "validate/2 add_connection with slot constraints" do
    test "rejects unknown target_input slot" do
      draft = base_draft()

      operation = %{
        type: :add_connection,
        payload: %{
          connection: %{
            id: "c_unknown",
            source_step_id: "model",
            target_step_id: "agent",
            source_output: "main",
            target_input: "unknown_slot"
          }
        }
      }

      assert {:error, {:invalid_target_input, "unknown_slot"}} =
               Operations.validate(draft, operation)
    end

    test "rejects source step type not accepted by slot" do
      draft = base_draft()

      operation = %{
        type: :add_connection,
        payload: %{
          connection: %{
            id: "c_bad_type",
            source_step_id: "math",
            target_step_id: "agent",
            source_output: "main",
            target_input: "model"
          }
        }
      }

      assert {:error, {:slot_disallows_source_type, "model", "math"}} =
               Operations.validate(draft, operation)
    end

    test "rejects additional connection to one-cardinality slot" do
      draft =
        base_draft()
        |> Map.put(:connections, [
          %Connection{
            id: "existing_model",
            source_step_id: "model",
            source_output: "main",
            target_step_id: "agent",
            target_input: "model"
          }
        ])

      operation = %{
        type: :add_connection,
        payload: %{
          connection: %{
            id: "c_extra_model",
            source_step_id: "model_alt",
            target_step_id: "agent",
            source_output: "main",
            target_input: "model"
          }
        }
      }

      assert {:error, {:slot_cardinality_exceeded, "model"}} =
               Operations.validate(draft, operation)
    end
  end

  defp base_draft do
    %WorkflowDraft{
      workflow_id: Ecto.UUID.generate(),
      steps: [
        step("agent", "ai_agent"),
        step("model", "openai_model"),
        step("model_alt", "anthropic_model"),
        step("prompt", "ai_prompt_template"),
        step("math", "math")
      ],
      connections: [],
      groups: []
    }
  end

  defp step(id, type_id) do
    %Step{
      id: id,
      type_id: type_id,
      name: id,
      config: %{},
      position: %{}
    }
  end
end
