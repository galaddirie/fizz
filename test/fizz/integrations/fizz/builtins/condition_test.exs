defmodule Fizz.Integrations.Library.Fizz.Builtins.ConditionTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.Library.Fizz.Builtins.Condition

  test "passes input through when condition is truthy" do
    input = %{"status" => "active"}

    assert {:ok, ^input} = Condition.execute(%{"condition" => true}, input, %{})
  end

  test "skips step when condition is falsey" do
    assert {:skip, :condition_false} = Condition.execute(%{"condition" => false}, %{}, %{})
  end

  test "treats common falsey values as false" do
    falsey_values = ["false", "", "0", nil, false, 0, 0.0, [], %{}]

    for value <- falsey_values do
      assert {:skip, :condition_false} = Condition.execute(%{"condition" => value}, %{}, %{})
    end
  end

  test "validate_config accepts non-empty strings" do
    assert :ok = Condition.validate_config(%{"condition" => "{{ json.status }} == \"active\""})
  end

  test "validate_config rejects missing or empty condition" do
    assert {:error, [condition: "is required"]} = Condition.validate_config(%{})

    assert {:error, [condition: "cannot be empty"]} =
             Condition.validate_config(%{"condition" => ""})

    assert {:error, [condition: "cannot be empty"]} =
             Condition.validate_config(%{"condition" => "   "})
  end
end
