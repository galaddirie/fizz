defmodule Fizz.Steps.TypeSubnodesTest do
  use ExUnit.Case, async: true

  alias Fizz.Steps.Registry

  test "ai_agent exposes declared subnode inputs in registry metadata" do
    assert {:ok, type} = Registry.get("ai_agent")
    assert type.node_role == :root
    assert is_list(type.subnode_inputs)
    assert Enum.any?(type.subnode_inputs, fn input -> input["id"] == "model" end)
    assert Enum.any?(type.subnode_inputs, fn input -> input["id"] == "prompt" end)
    assert Enum.any?(type.subnode_inputs, fn input -> input["id"] == "tools" end)
  end

  test "provider model nodes are registered as subnodes" do
    assert {:ok, openai_type} = Registry.get("openai_model")
    assert openai_type.node_role == :subnode

    assert {:ok, anthropic_type} = Registry.get("anthropic_model")
    assert anthropic_type.node_role == :subnode
  end
end
