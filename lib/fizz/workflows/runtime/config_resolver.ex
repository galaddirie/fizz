defmodule Fizz.Workflows.Runtime.ConfigResolver do
  @moduledoc false

  alias Fizz.Workflows.Expressions
  alias Fizz.Workflows.Expressions.AccessPlan

  @spec resolve_config(term(), map()) :: term()
  def resolve_config(compiled_config, context) do
    resolve_value(compiled_config, context)
  end

  @doc false
  @spec resolve_value(term(), map()) :: term()
  def resolve_value(%AccessPlan.Literal{} = plan, context),
    do: Expressions.resolve(plan, context)

  def resolve_value(%AccessPlan.ValueExpression{} = plan, context),
    do: Expressions.resolve(plan, context)

  def resolve_value(%AccessPlan.TemplateExpression{} = plan, context),
    do: Expressions.resolve(plan, context)

  def resolve_value(%AccessPlan.PredicateExpression{} = plan, context),
    do: Expressions.resolve(plan, context)

  def resolve_value(%AccessPlan.CredentialRef{} = plan, context),
    do: Expressions.resolve(plan, context)

  def resolve_value(map, context) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, resolve_value(value, context)} end)
  end

  def resolve_value(list, context) when is_list(list) do
    Enum.map(list, &resolve_value(&1, context))
  end

  def resolve_value(value, _context), do: value
end
