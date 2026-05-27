defmodule Fizz.Integrations.Fizz.Builtins.JoinTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.Fizz.Builtins.Join

  test "wait_all flattens one value from each branch" do
    assert {:ok, ["left", "right"]} =
             Join.execute(%{"mode" => "wait_all"}, [["left"], ["right"]], %{})
  end

  test "zip_nil pads shorter branches with nil" do
    assert {:ok, [[1, "a"], [2, nil]]} =
             Join.execute(%{"mode" => "zip_nil"}, [[1, 2], ["a"]], %{})
  end

  test "zip_shortest truncates to the shortest branch" do
    assert {:ok, [[1, "a"]]} =
             Join.execute(%{"mode" => "zip_shortest"}, [[1, 2], ["a"]], %{})
  end

  test "zip_cycle cycles shorter branches to match the longest branch" do
    assert {:ok, [[1, "a"], [2, "a"], [3, "a"]]} =
             Join.execute(%{"mode" => "zip_cycle"}, [[1, 2, 3], ["a"]], %{})
  end

  test "cartesian produces all combinations" do
    assert {:ok, [[1, "a"], [1, "b"], [2, "a"], [2, "b"]]} =
             Join.execute(%{"mode" => "cartesian"}, [[1, 2], ["a", "b"]], %{})
  end

  test "flatten flattens one level from the computed result" do
    assert {:ok, [1, "a", 2, "b"]} =
             Join.execute(%{"mode" => "zip_nil", "flatten" => true}, [[1, 2], ["a", "b"]], %{})
  end

  test "normalizes scalar input into a single branch list" do
    assert {:ok, [["value"]]} = Join.execute(%{"mode" => "zip_nil"}, "value", %{})
  end

  test "normalizes a plain list into a single branch" do
    assert {:ok, [[1], [2], [3]]} = Join.execute(%{"mode" => "zip_nil"}, [1, 2, 3], %{})
  end

  test "treats a list of lists as pre-grouped branch values" do
    assert {:ok, [[1, "a"], [2, "b"]]} =
             Join.execute(%{"mode" => "zip_nil"}, [[1, 2], ["a", "b"]], %{})
  end
end
