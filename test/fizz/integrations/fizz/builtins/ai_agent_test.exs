defmodule Fizz.Integrations.Fizz.Builtins.AIAgentTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.Fizz.Builtins.AIAgent

  test "unwraps nested structured schema subnode output when assembling payload" do
    json_schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"result" => %{"type" => "number"}},
      "required" => ["result"]
    }

    input = %{
      "_primary" => %{"number" => 7},
      "model" => %{
        "provider" => "openai_api_key",
        "credential_ref" => %{"id" => "credential-id", "provider" => "openai_api_key"},
        "model" => "gpt-5.5"
      },
      "structured_schema" => %{
        "name" => "multiply_by_10_result",
        "strict" => true,
        "json_schema" => %{
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

    assert get_in(output, ["structured_schema", "json_schema"]) == json_schema
    assert get_in(output, ["response_format", "json_schema", "schema"]) == json_schema
  end
end
