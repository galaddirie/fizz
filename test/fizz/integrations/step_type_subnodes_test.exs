defmodule Fizz.Integrations.Steps.TypeSubnodesTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.Steps.Registry, as: Registry

  test "ai_agent exposes declared subnode inputs in registry metadata" do
    assert {:ok, type} = Registry.get("ai_agent")
    assert type.node_role == :root
    assert is_list(type.subnode_inputs)
    assert Enum.any?(type.subnode_inputs, fn input -> input["id"] == "model" end)
    assert Enum.any?(type.subnode_inputs, fn input -> input["id"] == "structured_schema" end)
    assert Enum.any?(type.subnode_inputs, fn input -> input["id"] == "tools" end)
  end

  test "provider model nodes are registered as subnodes" do
    assert {:ok, openai_type} = Registry.get("openai_model")
    assert openai_type.node_role == :subnode

    assert {:ok, anthropic_type} = Registry.get("anthropic_model")
    assert anthropic_type.node_role == :subnode
  end

  test "ai structure schema is registered as a subnode" do
    assert {:ok, schema_type} = Registry.get("ai_structure_schema")
    assert schema_type.node_role == :subnode
  end
end
