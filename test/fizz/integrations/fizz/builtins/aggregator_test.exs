defmodule Fizz.Integrations.Library.Fizz.Builtins.AggregatorTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.Library.Fizz.Builtins.Aggregator

  test "collect returns the list unchanged" do
    assert {:ok, [1, 2, 3]} = Aggregator.execute(%{"operation" => "collect"}, [1, 2, 3], %{})
  end

  test "sum adds numeric items" do
    assert {:ok, 6} = Aggregator.execute(%{"operation" => "sum"}, [1, 2, 3], %{})
  end

  test "count returns the number of items" do
    assert {:ok, 3} = Aggregator.execute(%{"operation" => "count"}, ["a", "b", "c"], %{})
  end

  test "concat joins stringified values" do
    assert {:ok, "abc"} = Aggregator.execute(%{"operation" => "concat"}, ["a", "b", "c"], %{})
  end

  test "first returns the first item and last returns the last item" do
    assert {:ok, 1} = Aggregator.execute(%{"operation" => "first"}, [1, 2, 3], %{})
    assert {:ok, 3} = Aggregator.execute(%{"operation" => "last"}, [1, 2, 3], %{})
  end

  test "min and max return the expected bounds" do
    assert {:ok, 1} = Aggregator.execute(%{"operation" => "min"}, [3, 1, 2], %{})
    assert {:ok, 3} = Aggregator.execute(%{"operation" => "max"}, [3, 1, 2], %{})
  end

  test "empty list semantics match each operation's default" do
    assert {:ok, []} = Aggregator.execute(%{"operation" => "collect"}, [], %{})
    assert {:ok, 0} = Aggregator.execute(%{"operation" => "sum"}, [], %{})
    assert {:ok, 0} = Aggregator.execute(%{"operation" => "count"}, [], %{})
    assert {:ok, ""} = Aggregator.execute(%{"operation" => "concat"}, [], %{})
    assert {:ok, nil} = Aggregator.execute(%{"operation" => "first"}, [], %{})
    assert {:ok, nil} = Aggregator.execute(%{"operation" => "last"}, [], %{})
    assert {:ok, nil} = Aggregator.execute(%{"operation" => "min"}, [], %{})
    assert {:ok, nil} = Aggregator.execute(%{"operation" => "max"}, [], %{})
  end

  test "init_for_operation exposes the same defaults used by reductions" do
    assert [] == Aggregator.init_for_operation("collect")
    assert 0 == Aggregator.init_for_operation("sum")
    assert 0 == Aggregator.init_for_operation("count")
    assert "" == Aggregator.init_for_operation("concat")
    assert nil == Aggregator.init_for_operation("first")
    assert nil == Aggregator.init_for_operation("last")
    assert nil == Aggregator.init_for_operation("min")
    assert nil == Aggregator.init_for_operation("max")
  end
end
