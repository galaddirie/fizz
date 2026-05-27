defmodule Fizz.Integrations.Fizz.Builtins.SwitchTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.Fizz.Builtins.Switch

  test "routes to matched branch using pre-resolved value" do
    config = %{
      "value" => "active",
      "cases" => [
        %{"match" => "pending", "output" => "pending"},
        %{"match" => "active", "output" => "active"}
      ],
      "default_output" => "other"
    }

    input = %{"status" => "active"}

    assert {:ok, {:branch, "active", ^input}} = Switch.execute(config, input, %{})
  end

  test "routes to default output when no case matches" do
    config = %{
      "value" => "unknown",
      "cases" => [%{"match" => "active", "output" => "active"}],
      "default_output" => "other"
    }

    input = %{"status" => "unknown"}

    assert {:ok, {:branch, "other", ^input}} = Switch.execute(config, input, %{})
  end

  test "does not evaluate runtime expressions in execute" do
    config = %{
      "value" => "{{ json.status }}",
      "cases" => [%{"match" => "{{ json.status }}", "output" => "literal"}],
      "default_output" => "default"
    }

    input = %{"status" => "active"}

    assert {:ok, {:branch, "literal", ^input}} = Switch.execute(config, input, %{})
  end

  test "normalizes values while matching" do
    config = %{
      "value" => 42,
      "cases" => [%{"match" => "42", "output" => "number"}]
    }

    input = %{"value" => 42}

    assert {:ok, {:branch, "number", ^input}} = Switch.execute(config, input, %{})
  end

  test "validate_config enforces required fields" do
    assert {:error, [value: "is required", cases: "is required"]} = Switch.validate_config(%{})

    assert {:error, [value: "cannot be empty"]} =
             Switch.validate_config(%{
               "value" => "",
               "cases" => [%{"match" => "x", "output" => "branch"}]
             })

    assert {:error, [cases: "must have at least one case"]} =
             Switch.validate_config(%{"value" => "x", "cases" => []})
  end
end
