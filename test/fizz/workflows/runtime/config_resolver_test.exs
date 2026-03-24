defmodule Fizz.Workflows.Runtime.ConfigResolverTest do
  use ExUnit.Case, async: true

  alias Fizz.Workflows.Expressions
  alias Fizz.Workflows.Expressions.AccessPlan
  alias Fizz.Workflows.Runtime.ConfigResolver

  test "resolve_config preserves native values for input expressions" do
    compiled_config = %{"orders" => access_plan!("{{ input.orders }}")}
    orders = [%{"id" => 1}, %{"id" => 2}]

    assert ConfigResolver.resolve_config(compiled_config, context(%{"orders" => orders}, %{})) ==
             %{"orders" => orders}
  end

  test "resolve_config preserves native values for json aliases" do
    compiled_config = %{"orders" => access_plan!("{{ json.orders }}")}
    orders = [%{"id" => 1}, %{"id" => 2}]

    assert ConfigResolver.resolve_config(compiled_config, context(%{"orders" => orders}, %{})) ==
             %{"orders" => orders}
  end

  test "resolve_config renders template expressions to strings" do
    compiled_config = %{"message" => access_plan!("Hello {{ input.name }}")}

    assert ConfigResolver.resolve_config(compiled_config, context(%{"name" => "Ada"}, %{})) == %{
             "message" => "Hello Ada"
           }
  end

  test "resolve_config reads step outputs using stable uuid references" do
    step_id = Ecto.UUID.generate()

    compiled_config = %{
      "value" => access_plan!("{{ steps.#{step_id}.body }}", known_step_ids: [step_id])
    }

    resolved =
      ConfigResolver.resolve_config(
        compiled_config,
        context(%{}, %{step_id => %{"body" => %{"ok" => true}}})
      )

    assert resolved == %{"value" => %{"ok" => true}}
  end

  test "fast path resolves simple lookups without invoking Solid" do
    compiled_config = %{
      "orders" => %AccessPlan.ValueExpression{
        path: ["input", "orders"],
        parsed: :unused,
        filters: []
      }
    }

    assert ConfigResolver.resolve_config(compiled_config, context(%{"orders" => [1, 2, 3]}, %{})) ==
             %{"orders" => [1, 2, 3]}
  end

  defp access_plan!(expression, opts \\ []) do
    {:ok, plan} =
      Expressions.to_access_plan(
        expression,
        Keyword.merge([strict_filters: true, known_step_ids: []], opts)
      )

    plan
  end

  defp context(input, steps) do
    %{
      input: input,
      steps: steps,
      workflow: %{},
      env: %{}
    }
  end
end
