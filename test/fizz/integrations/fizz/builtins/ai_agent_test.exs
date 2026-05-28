defmodule Fizz.Integrations.Library.Fizz.Builtins.AIAgentTest do
  use ExUnit.Case, async: false

  alias Fizz.Integrations.Library.Fizz.Builtins.AIAgent

  alias Fizz.Integrations.Library.Fizz.Builtins.ChatModelProviders.Registry,
    as: ChatModelProviderRegistry

  defmodule ReqLLMResponseProvider do
    @behaviour Fizz.Integrations.Library.Fizz.Builtins.ChatModelProviders.Provider

    @impl true
    def provider_prefix, do: "test"

    @impl true
    def generate(_request, _context) do
      {:ok,
       %ReqLLM.Response{
         id: "resp_test",
         model: "test-model",
         context: nil,
         message: %ReqLLM.Message{
           role: :assistant,
           content: [ReqLLM.Message.ContentPart.text("done")],
           tool_calls: [
             ReqLLM.ToolCall.new("call_test", "lookup_contact", ~s({"email":"ada@example.com"}))
           ]
         },
         object: %{accepted: true},
         usage: %{input_tokens: 7, output_tokens: 3, total_tokens: 10},
         finish_reason: :stop
       }}
    end
  end

  test "unwraps nested structured schema dependency output when assembling payload" do
    json_schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"result" => %{"type" => "number"}},
      "required" => ["result"]
    }

    input = %{
      "main" => %{"number" => 7},
      "model" => %{
        "kind" => "ai.chat_model",
        "provider" => "openai_api_key",
        "credential_ref" => %{"id" => "credential-id", "provider" => "openai_api_key"},
        "model_spec" => "openai:gpt-5.5"
      },
      "structured_schema" => %{
        "kind" => "ai.schema",
        "name" => "multiply_by_10_result",
        "strict" => true,
        "schema" => %{
          "name" => "multiply_by_10_result",
          "strict" => true,
          "json_schema" => json_schema
        }
      }
    }

    assert {:ok, output} =
             AIAgent.execute(
               %{"mode" => "assemble_only", "user_message" => "Multiply 7 by 10"},
               input,
               %{}
             )

    assert get_in(output, ["structured_schema", "schema"]) == json_schema
    assert get_in(output, ["response_format", "json_schema", "schema"]) == json_schema
  end

  test "provider chat stores a JSON-safe response payload" do
    previous_registry_config = Application.get_env(:fizz, ChatModelProviderRegistry)

    Application.put_env(:fizz, ChatModelProviderRegistry,
      provider_modules: [ReqLLMResponseProvider]
    )

    on_exit(fn ->
      if is_nil(previous_registry_config) do
        Application.delete_env(:fizz, ChatModelProviderRegistry)
      else
        Application.put_env(:fizz, ChatModelProviderRegistry, previous_registry_config)
      end
    end)

    input = %{
      "main" => %{"email" => [1, 2]},
      "model" => %{
        "kind" => "ai.chat_model",
        "provider" => "test",
        "credential_ref" => %{"id" => "credential-id", "provider" => "test"},
        "model_spec" => "test:model"
      }
    }

    assert {:ok, output} =
             AIAgent.execute(
               %{"mode" => "provider_chat", "user_message" => "{{ json }}"},
               input,
               %{}
             )

    assert output["response"] == %{
             "finish_reason" => "stop",
             "id" => "resp_test",
             "model" => "test-model",
             "object" => %{"accepted" => true},
             "ok" => true,
             "text" => "done",
             "tool_calls" => [
               %{
                 "function" => %{
                   "arguments" => ~s({"email":"ada@example.com"}),
                   "name" => "lookup_contact"
                 },
                 "id" => "call_test",
                 "type" => "function"
               }
             ],
             "usage" => %{
               "input_tokens" => 7,
               "output_tokens" => 3,
               "total_tokens" => 10
             }
           }
  end
end
