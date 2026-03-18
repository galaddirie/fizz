defmodule Fizz.Steps.Executors.SplitterTest do
  use ExUnit.Case, async: true

  alias Fizz.Steps.Executors.Splitter

  test "returns an empty list when input is nil" do
    assert {:ok, []} = Splitter.execute(%{}, nil, %{})
  end

  test "wraps a scalar input in a single-item list" do
    assert {:ok, [42]} = Splitter.execute(%{}, 42, %{})
  end

  test "converts a map input into key value tuples" do
    assert {:ok, entries} = Splitter.execute(%{}, %{"a" => 1, "b" => 2}, %{})

    assert Enum.sort(entries) == [{"a", 1}, {"b", 2}]
  end

  test "converts a range input into a list" do
    assert {:ok, [1, 2, 3]} = Splitter.execute(%{}, 1..3, %{})
  end

  test "extracts items from a configured field path" do
    input = %{"payload" => %{"items" => ["a", "b", "c"]}}

    assert {:ok, ["a", "b", "c"]} =
             Splitter.execute(%{"field" => "payload.items"}, input, %{})
  end
end
