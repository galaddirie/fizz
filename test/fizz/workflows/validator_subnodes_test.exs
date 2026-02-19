defmodule Fizz.Workflows.ValidatorSubnodesTest do
  use ExUnit.Case, async: true

  alias Fizz.Workflows.Validator
  alias Fizz.Workflows.WorkflowDraft
  alias Fizz.Workflows.Embeds.{Connection, Step}

  describe "validate/1 subnode slots" do
    test "accepts valid slot wiring" do
      draft = %WorkflowDraft{
        workflow_id: Ecto.UUID.generate(),
        steps: [
          step("agent", "ai_agent"),
          step("model", "openai_model"),
          step("prompt", "ai_prompt_template"),
          step("tool", "ai_tool_http")
        ],
        connections: [
          conn("c1", "model", "agent", "model"),
          conn("c2", "prompt", "agent", "prompt"),
          conn("c3", "tool", "agent", "tools")
        ],
        groups: []
      }

      assert :ok = Validator.validate(draft)
    end

    test "fails when required slots are missing" do
      draft = %WorkflowDraft{
        workflow_id: Ecto.UUID.generate(),
        steps: [
          step("agent", "ai_agent"),
          step("model", "openai_model")
        ],
        connections: [
          conn("c1", "model", "agent", "model")
        ],
        groups: []
      }

      assert {:error, errors} = Validator.validate(draft)
      assert Enum.any?(errors, fn error -> inspect(error) =~ "required slot prompt" end)
    end

    test "fails when source type is not accepted by slot" do
      draft = %WorkflowDraft{
        workflow_id: Ecto.UUID.generate(),
        steps: [
          step("agent", "ai_agent"),
          step("math", "math"),
          step("prompt", "ai_prompt_template")
        ],
        connections: [
          conn("c1", "math", "agent", "model"),
          conn("c2", "prompt", "agent", "prompt")
        ],
        groups: []
      }

      assert {:error, errors} = Validator.validate(draft)

      assert Enum.any?(errors, fn error ->
               inspect(error) =~ "is not allowed for slot model"
             end)
    end

    test "fails when one-cardinality slot has multiple connections" do
      draft = %WorkflowDraft{
        workflow_id: Ecto.UUID.generate(),
        steps: [
          step("agent", "ai_agent"),
          step("model_a", "openai_model"),
          step("model_b", "anthropic_model"),
          step("prompt", "ai_prompt_template")
        ],
        connections: [
          conn("c1", "model_a", "agent", "model"),
          conn("c2", "model_b", "agent", "model"),
          conn("c3", "prompt", "agent", "prompt")
        ],
        groups: []
      }

      assert {:error, errors} = Validator.validate(draft)

      assert Enum.any?(errors, fn error ->
               inspect(error) =~ "allows only one sub-node connection"
             end)
    end
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

  defp conn(id, source, target, target_input) do
    %Connection{
      id: id,
      source_step_id: source,
      source_output: "main",
      target_step_id: target,
      target_input: target_input
    }
  end
end
