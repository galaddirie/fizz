defmodule Fizz.Integrations.Steps.ConnectionHandleMetadataTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.Steps.ConnectionHandles
  alias Fizz.Integrations.Steps.Registry, as: Registry

  test "ai_agent exposes declared dependency inputs in input schema metadata" do
    assert {:ok, type} = Registry.get("ai_agent")
    handles = ConnectionHandles.input_handles(type)

    assert %{kind: :flow} = Enum.find(handles, &(&1.id == "main"))

    assert %{kind: :dependency, required?: true, accepts: %{provides: ["ai.chat_model"]}} =
             Enum.find(handles, &(&1.id == "model"))

    assert %{kind: :dependency, accepts: %{provides: ["ai.schema"]}} =
             Enum.find(handles, &(&1.id == "structured_schema"))

    assert %{kind: :dependency, cardinality: :many, accepts: %{provides: ["ai.tool"]}} =
             Enum.find(handles, &(&1.id == "tools"))
  end

  test "provider model nodes declare chat model output capabilities" do
    assert {:ok, openai_type} = Registry.get("openai_model")
    assert {:ok, openai_outputs} = ConnectionHandles.output_handles(openai_type)
    assert %{provides: ["ai.chat_model"]} = Enum.find(openai_outputs, &(&1.id == "main"))

    assert {:ok, anthropic_type} = Registry.get("anthropic_model")
    assert {:ok, anthropic_outputs} = ConnectionHandles.output_handles(anthropic_type)
    assert %{provides: ["ai.chat_model"]} = Enum.find(anthropic_outputs, &(&1.id == "main"))
  end

  test "schema and tool nodes declare semantic dependency capabilities" do
    assert {:ok, schema_type} = Registry.get("ai_structure_schema")
    assert {:ok, schema_outputs} = ConnectionHandles.output_handles(schema_type)
    assert %{provides: ["ai.schema"]} = Enum.find(schema_outputs, &(&1.id == "main"))

    assert {:ok, tool_type} = Registry.get("ai_tool_http")
    assert {:ok, tool_outputs} = ConnectionHandles.output_handles(tool_type)
    assert %{provides: ["ai.tool"]} = Enum.find(tool_outputs, &(&1.id == "main"))
  end
end
