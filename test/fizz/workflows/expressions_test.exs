defmodule Fizz.Workflows.ExpressionsTest do
  use ExUnit.Case, async: true

  alias Fizz.Workflows.Expressions
  alias Fizz.Workflows.Expressions.Filters

  test "classifies literal, value, template, and predicate expressions" do
    assert Expressions.classify("plain text") == :literal
    assert Expressions.classify("{{ input.orders }}") == :value
    assert Expressions.classify("Hello {{ input.name }}") == :template
    assert Expressions.classify("{{ input.total | gt: 100 }}") == :predicate
  end

  test "resolves value expressions while preserving native types" do
    orders = [%{"id" => 1}, %{"id" => 2}]
    plan = access_plan!("{{ input.orders }}")

    assert Expressions.resolve(plan, context(%{"orders" => orders})) == orders
  end

  test "resolves template expressions to strings" do
    plan = access_plan!("Hello {{ input.name }}")

    assert Expressions.resolve(plan, context(%{"name" => "Ada"})) == "Hello Ada"
  end

  test "preview renders value expressions with native types" do
    orders = [%{"id" => 1}, %{"id" => 2}]

    assert Expressions.preview("{{ input.orders }}", context(%{"orders" => orders})) ==
             {:ok, orders}
  end

  test "preview returns parse errors for invalid expressions" do
    assert {:error, message} =
             Expressions.preview("{% if input.ok %}", context(%{"ok" => true}))

    assert String.starts_with?(message, "Parse error: ")
  end

  test "validate rejects unsupported filters in strict mode" do
    assert {:error, errors} =
             Expressions.validate("{{ input.name | concat: \"!\" }}",
               strict_filters: true,
               known_step_ids: []
             )

    assert Enum.any?(errors, &String.contains?(&1, "unsupported filter `concat`"))
  end

  test "custom filters produce the expected values" do
    assert Filters.json(%{"ok" => true}) == "{\"ok\":true}"
    assert Filters.parse_json("{\"ok\":true}") == %{"ok" => true}
    assert Filters.to_int("12.8") == 12
    assert Filters.to_float("12") == 12.0
    assert Filters.to_bool("true")

    assert Filters.dig(%{"customer" => %{"email" => "ada@example.com"}}, "customer.email") ==
             "ada@example.com"

    assert Filters.pluck([%{"id" => 1}, %{"id" => 2}], "id") == [1, 2]
    assert Filters.sort_by([%{"id" => 2}, %{"id" => 1}], "id") == [%{"id" => 1}, %{"id" => 2}]

    assert Filters.sort_by_desc([%{"id" => 1}, %{"id" => 2}], "id") == [
             %{"id" => 2},
             %{"id" => 1}
           ]

    assert Filters.where_eq([%{"status" => "paid"}, %{"status" => "draft"}], "status", "paid") ==
             [%{"status" => "paid"}]

    assert Filters.where_ne([%{"status" => "paid"}, %{"status" => "draft"}], "status", "paid") ==
             [%{"status" => "draft"}]

    assert Filters.eq("10", 10)
    assert Filters.ne("paid", "draft")
    assert Filters.gt("11", 10)
    assert Filters.gte(10, "10")
    assert Filters.lt(9, "10")
    assert Filters.lte("10", 10)
    assert Filters.blank("   ")
    assert Filters.present("Ada")
    assert Filters.slugify("Hello, Ada Lovelace!") == "hello-ada-lovelace"
  end

  test "step reference validation rejects non-existent step ids" do
    step_id = Ecto.UUID.generate()

    assert {:error, errors} =
             Expressions.validate("{{ steps.#{step_id}.body }}",
               strict_filters: true,
               known_step_ids: []
             )

    assert Enum.any?(errors, &String.contains?(&1, step_id))
  end

  defp access_plan!(expression) do
    {:ok, plan} =
      Expressions.to_access_plan(expression,
        strict_filters: true,
        known_step_ids: []
      )

    plan
  end

  defp context(input) do
    %{
      input: input,
      steps: %{},
      workflow: %{},
      env: %{}
    }
  end
end
