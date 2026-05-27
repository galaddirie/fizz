defmodule Fizz.Integrations.Fizz.Builtins.AIStructureSchemaTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.Fizz.Builtins.AIStructureSchema

  test "unwraps a full structure schema pasted into the json_schema field" do
    json_schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "result" => %{
          "type" => "number",
          "description" => "The input number multiplied by 10."
        }
      },
      "required" => ["result"]
    }

    config = %{
      "name" => "multiply_by_10_result",
      "strict" => true,
      "json_schema" => %{
        "name" => "multiply_by_10_result",
        "strict" => true,
        "json_schema" => json_schema
      }
    }

    assert {:ok, output} = AIStructureSchema.execute(config, %{}, %{})
    assert output["json_schema"] == json_schema
    assert get_in(output, ["response_format", "json_schema", "schema"]) == json_schema
  end
end
