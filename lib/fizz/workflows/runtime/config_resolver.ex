defmodule Fizz.Workflows.Runtime.ConfigResolver do
  @moduledoc false

  alias Fizz.Workflows.Expressions
  alias Fizz.Workflows.Expressions.AccessPlan

  @spec resolve_config(term(), map()) :: term()
  def resolve_config(compiled_config, context) do
    resolve_value(compiled_config, context)
  end

  defp resolve_value(%AccessPlan.Literal{} = plan, context),
    do: Expressions.resolve(plan, context)

  defp resolve_value(%AccessPlan.ValueExpression{} = plan, context),
    do: Expressions.resolve(plan, context)

  defp resolve_value(%AccessPlan.TemplateExpression{} = plan, context),
    do: Expressions.resolve(plan, context)

  defp resolve_value(%AccessPlan.PredicateExpression{} = plan, context),
    do: Expressions.resolve(plan, context)

  defp resolve_value(%AccessPlan.SlotRef{} = plan, context),
    do: Expressions.resolve(plan, context)

  defp resolve_value(map, context) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, resolve_value(value, context)} end)
  end

  defp resolve_value(list, context) when is_list(list) do
    Enum.map(list, &resolve_value(&1, context))
  end

  defp resolve_value(value, _context), do: value
end
