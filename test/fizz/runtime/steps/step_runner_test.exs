defmodule Fizz.Runtime.Steps.StepRunnerTest do
  use ExUnit.Case, async: true

  alias Fizz.Runtime.Steps.StepRunner
  alias Fizz.Workflows.Embeds.Step

  describe "execute_with_context/3 with subnode slots" do
    test "injects subnode outputs and keeps primary input isolated" do
      step = %Step{
        id: "agent_step",
        type_id: "ai_agent",
        name: "Agent",
        config: %{"mode" => "assemble_only"},
        position: %{}
      }

      result =
        StepRunner.execute_with_context(
          step,
          %{"joined" => "raw_input"},
          execution_opts(%{
            "main_input_step" => %{"question" => "What is Elixir?"},
            "model_step" => %{
              "provider" => "openai_api_key",
              "credential_ref" => %{
                "id" => "cred_openai",
                "provider" => "openai_api_key",
                "auth_type" => "api_key",
                "owner_user_id" => "user_123"
              },
              "model" => "gpt-4.1-mini",
              "temperature" => 0.1,
              "max_tokens" => 240
            },
            "prompt_step" => %{
              "messages" => [%{"role" => "user", "content" => "Explain Elixir briefly."}]
            },
            "tool_step_1" => %{"type" => "http", "name" => "docs"}
          })
        )

      assert result["_primary"] == %{"question" => "What is Elixir?"}
      assert result["model"] == "gpt-4.1-mini"
      assert result["provider"] == "openai_api_key"
      assert result["tools"] == [%{"type" => "http", "name" => "docs"}]
      assert is_list(result["messages"])
    end

    test "sets _primary to nil when no primary input edge exists" do
      step = %Step{
        id: "agent_step",
        type_id: "ai_agent",
        name: "Agent",
        config: %{"mode" => "assemble_only"},
        position: %{}
      }

      result =
        StepRunner.execute_with_context(
          step,
          %{"joined" => "slot_only"},
          execution_opts(
            %{
              "model_step" => %{
                "provider" => "openai_api_key",
                "credential_ref" => %{
                  "id" => "cred_openai",
                  "provider" => "openai_api_key",
                  "auth_type" => "api_key",
                  "owner_user_id" => "user_123"
                },
                "model" => "gpt-4.1-mini"
              },
              "prompt_step" => %{"messages" => [%{"role" => "user", "content" => "Hi"}]}
            },
            primary_parents: []
          )
        )

      assert result["_primary"] == nil
    end
  end

  defp execution_opts(step_outputs, opts \\ []) do
    primary_parents = Keyword.get(opts, :primary_parents, ["main_input_step"])

    [
      execution_id: "exec_test",
      workflow_id: "wf_test",
      step_outputs: step_outputs,
      upstream_lookup: %{
        "agent_step" => Map.keys(step_outputs)
      },
      primary_parent_lookup: %{
        "agent_step" => primary_parents
      },
      slot_bindings: %{
        "agent_step" => %{
          "model" => ["model_step"],
          "prompt" => ["prompt_step"],
          "tools" => ["tool_step_1"]
        }
      }
    ]
  end
end
