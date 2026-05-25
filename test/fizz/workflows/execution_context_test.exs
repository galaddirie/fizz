defmodule Fizz.Workflows.ExecutionContextTest do
  use ExUnit.Case, async: true

  alias Fizz.Workflows.ExecutionContext

  describe "put_legacy_aliases/1" do
    test "preserves falsey input values in legacy and typed context" do
      context = ExecutionContext.put_legacy_aliases(%{input: false, type_id: "debug"})

      assert context.input == false
      assert %ExecutionContext{} = context.execution_context
      assert context.execution_context.input == false
      assert context.execution_context.type_id == "debug"
    end
  end
end
