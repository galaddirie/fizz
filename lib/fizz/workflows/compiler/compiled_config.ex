defmodule Fizz.Workflows.Compiler.CompiledConfig do
  @moduledoc false

  alias Fizz.Workflows.Expressions.AccessPlan

  @spec optional_literal_string(term(), String.t() | nil) :: String.t() | nil
  def optional_literal_string(nil, default), do: default
  def optional_literal_string(%AccessPlan.Literal{value: nil}, default), do: default

  def optional_literal_string(%AccessPlan.Literal{value: value}, _default)
      when is_binary(value),
      do: value

  def optional_literal_string(%AccessPlan.Literal{value: value}, label) do
    raise ArgumentError, "#{label} must resolve to a string literal, got: #{inspect(value)}"
  end

  def optional_literal_string(value, _default) when is_binary(value), do: value

  def optional_literal_string(value, label) do
    raise ArgumentError, "#{label} must resolve to a string literal, got: #{inspect(value)}"
  end

  @spec required_literal_string!(term(), String.t()) :: String.t()
  def required_literal_string!(nil, label) do
    raise ArgumentError, "#{label} must resolve to a string literal, got: nil"
  end

  def required_literal_string!(%AccessPlan.Literal{value: nil}, label) do
    raise ArgumentError, "#{label} must resolve to a string literal, got: nil"
  end

  def required_literal_string!(value, label), do: optional_literal_string(value, label)
end
