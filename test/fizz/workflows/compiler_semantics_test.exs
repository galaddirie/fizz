defmodule Fizz.Workflows.CompilerSemanticsTest do
  use ExUnit.Case, async: true

  import Fizz.Workflows.CompilerScenarioHelper

  alias Fizz.Workflows.Compiler

  test "plain diamond outside split waits for both parents in authored order" do
    root = step(%{id: Ecto.UUID.generate(), type_id: "manual_input", name: "Entry"})
    add = math_step("Add One", "add", "{{ input }}", 1)
    multiply = math_step("Times Ten", "multiply", "{{ input }}", 10)
    sink = step(%{id: Ecto.UUID.generate(), type_id: "data_output", name: "Out"})

    workflow =
      [root, add, multiply, sink]
      |> version([
        connection(%{source_step_id: root.id, target_step_id: add.id}),
        connection(%{source_step_id: root.id, target_step_id: multiply.id}),
        connection(%{source_step_id: add.id, target_step_id: sink.id}),
        connection(%{source_step_id: multiply.id, target_step_id: sink.id})
      ])
      |> compile!()
      |> elem(0)
      |> react(2)

    assert productions(workflow, sink.id) == [[3, 20]]
  end

  test "explicit join outside split defaults to wait_all semantics" do
    root = step(%{id: Ecto.UUID.generate(), type_id: "manual_input", name: "Entry"})
    add = math_step("Add One", "add", "{{ input }}", 1)
    multiply = math_step("Times Ten", "multiply", "{{ input }}", 10)
    join = step(%{id: Ecto.UUID.generate(), type_id: "join", name: "Join", config: %{}})

    workflow =
      [root, add, multiply, join]
      |> version([
        connection(%{source_step_id: root.id, target_step_id: add.id}),
        connection(%{source_step_id: root.id, target_step_id: multiply.id}),
        connection(%{source_step_id: add.id, target_step_id: join.id}),
        connection(%{source_step_id: multiply.id, target_step_id: join.id})
      ])
      |> compile!()
      |> elem(0)
      |> react(2)

    assert productions(workflow, join.id) == [[3, 20]]
  end

  test "splitter to aggregator preserves order across map-reduce fan-in" do
    {workflow, aggregator_id} = split_collect_workflow()
    workflow = react(workflow, %{"items" => [3, 1, 2]})

    assert productions(workflow, aggregator_id) == [[6, 2, 4]]
  end

  test "splitter to aggregator emits one result for a single split item" do
    {workflow, aggregator_id} = split_collect_workflow()
    workflow = react(workflow, %{"items" => [4]})

    assert productions(workflow, aggregator_id) == [[8]]
  end

  test "splitter to aggregator emits the operation default for an empty split" do
    {workflow, aggregator_id} = split_collect_workflow()
    workflow = react(workflow, %{"items" => []})

    assert productions(workflow, aggregator_id) == [[]]
  end

  test "same-lineage split branches require an explicit join and zip together deterministically" do
    root = step(%{id: Ecto.UUID.generate(), type_id: "manual_input", name: "Entry"})

    splitter =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "splitter",
        name: "Split",
        config: %{"field" => "items"}
      })

    add = math_step("Add One", "add", "{{ input }}", 1)
    multiply = math_step("Times Ten", "multiply", "{{ input }}", 10)

    join =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "join",
        name: "Join",
        config: %{"mode" => "zip_nil"}
      })

    workflow =
      [root, splitter, add, multiply, join]
      |> version([
        connection(%{source_step_id: root.id, target_step_id: splitter.id}),
        connection(%{source_step_id: splitter.id, target_step_id: add.id}),
        connection(%{source_step_id: splitter.id, target_step_id: multiply.id}),
        connection(%{source_step_id: add.id, target_step_id: join.id}),
        connection(%{source_step_id: multiply.id, target_step_id: join.id})
      ])
      |> compile!()
      |> elem(0)
      |> react(%{"items" => [1, 2, 3]})

    assert productions(workflow, join.id) == [[[2, 10], [3, 20], [4, 30]]]
  end

  test "mixing split and non-split parents defaults to zip_nil semantics" do
    root = step(%{id: Ecto.UUID.generate(), type_id: "manual_input", name: "Entry"})

    splitter =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "splitter",
        name: "Split",
        config: %{"field" => "items"}
      })

    add = math_step("Add One", "add", "{{ input }}", 1)
    whole = step(%{id: Ecto.UUID.generate(), type_id: "data_output", name: "Whole"})

    join =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "join",
        name: "Join",
        config: %{}
      })

    input = %{"items" => [1, 2], "label" => "Ada"}

    workflow =
      [root, splitter, add, whole, join]
      |> version([
        connection(%{source_step_id: root.id, target_step_id: splitter.id}),
        connection(%{source_step_id: root.id, target_step_id: whole.id}),
        connection(%{source_step_id: splitter.id, target_step_id: add.id}),
        connection(%{source_step_id: add.id, target_step_id: join.id}),
        connection(%{source_step_id: whole.id, target_step_id: join.id})
      ])
      |> compile!()
      |> elem(0)
      |> react(input)

    assert productions(workflow, join.id) == [[[2, input], [3, nil]]]
  end

  test "joining two different splitters uses explicit cartesian semantics" do
    root = step(%{id: Ecto.UUID.generate(), type_id: "manual_input", name: "Entry"})

    left_splitter =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "splitter",
        name: "Split Left",
        config: %{"field" => "left"}
      })

    right_splitter =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "splitter",
        name: "Split Right",
        config: %{"field" => "right"}
      })

    add = math_step("Add One", "add", "{{ input }}", 1)
    multiply = math_step("Times Ten", "multiply", "{{ input }}", 10)

    join =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "join",
        name: "Join",
        config: %{"mode" => "cartesian"}
      })

    workflow =
      [root, left_splitter, right_splitter, add, multiply, join]
      |> version([
        connection(%{source_step_id: root.id, target_step_id: left_splitter.id}),
        connection(%{source_step_id: root.id, target_step_id: right_splitter.id}),
        connection(%{source_step_id: left_splitter.id, target_step_id: add.id}),
        connection(%{source_step_id: right_splitter.id, target_step_id: multiply.id}),
        connection(%{source_step_id: add.id, target_step_id: join.id}),
        connection(%{source_step_id: multiply.id, target_step_id: join.id})
      ])
      |> compile!()
      |> elem(0)
      |> react(%{"left" => [1, 2], "right" => [3, 4]})

    assert productions(workflow, join.id) == [[[2, 30], [2, 40], [3, 30], [3, 40]]]
  end

  test "joining split branches with different sizes defaults to zip_nil padding" do
    root = step(%{id: Ecto.UUID.generate(), type_id: "manual_input", name: "Entry"})

    left_splitter =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "splitter",
        name: "Split Left",
        config: %{"field" => "left"}
      })

    right_splitter =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "splitter",
        name: "Split Right",
        config: %{"field" => "right"}
      })

    add = math_step("Add One", "add", "{{ input }}", 1)
    multiply = math_step("Times Ten", "multiply", "{{ input }}", 10)
    join = step(%{id: Ecto.UUID.generate(), type_id: "join", name: "Join", config: %{}})

    workflow =
      [root, left_splitter, right_splitter, add, multiply, join]
      |> version([
        connection(%{source_step_id: root.id, target_step_id: left_splitter.id}),
        connection(%{source_step_id: root.id, target_step_id: right_splitter.id}),
        connection(%{source_step_id: left_splitter.id, target_step_id: add.id}),
        connection(%{source_step_id: right_splitter.id, target_step_id: multiply.id}),
        connection(%{source_step_id: add.id, target_step_id: join.id}),
        connection(%{source_step_id: multiply.id, target_step_id: join.id})
      ])
      |> compile!()
      |> elem(0)
      |> react(%{"left" => [1, 2, 3], "right" => [10, 20, 30, 40, 50]})

    assert productions(workflow, join.id) == [
             [[2, 100], [3, 200], [4, 300], [nil, 400], [nil, 500]]
           ]
  end

  test "compiler rejects implicit split convergence without an explicit join" do
    root = step(%{id: Ecto.UUID.generate(), type_id: "manual_input", name: "Entry"})

    splitter =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "splitter",
        name: "Split",
        config: %{"field" => "items"}
      })

    add = math_step("Add One", "add", "{{ input }}", 1)
    multiply = math_step("Times Ten", "multiply", "{{ input }}", 10)
    sink = step(%{id: Ecto.UUID.generate(), type_id: "data_output", name: "Out"})

    version =
      version(
        [root, splitter, add, multiply, sink],
        [
          connection(%{source_step_id: root.id, target_step_id: splitter.id}),
          connection(%{source_step_id: splitter.id, target_step_id: add.id}),
          connection(%{source_step_id: splitter.id, target_step_id: multiply.id}),
          connection(%{source_step_id: add.id, target_step_id: sink.id}),
          connection(%{source_step_id: multiply.id, target_step_id: sink.id})
        ]
      )

    assert_compile_error(version, "insert an explicit `join` step")
  end

  test "aggregator implicitly zips same-depth split branches for row-safe operations" do
    root = step(%{id: Ecto.UUID.generate(), type_id: "manual_input", name: "Entry"})

    left_splitter =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "splitter",
        name: "Split Left",
        config: %{"field" => "left"}
      })

    right_splitter =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "splitter",
        name: "Split Right",
        config: %{"field" => "right"}
      })

    add = math_step("Add One", "add", "{{ input }}", 1)
    multiply = math_step("Times Ten", "multiply", "{{ input }}", 10)

    aggregator =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "aggregator",
        name: "Collect",
        config: %{"operation" => "collect"}
      })

    workflow =
      [root, left_splitter, right_splitter, add, multiply, aggregator]
      |> version([
        connection(%{source_step_id: root.id, target_step_id: left_splitter.id}),
        connection(%{source_step_id: root.id, target_step_id: right_splitter.id}),
        connection(%{source_step_id: left_splitter.id, target_step_id: add.id}),
        connection(%{source_step_id: right_splitter.id, target_step_id: multiply.id}),
        connection(%{source_step_id: add.id, target_step_id: aggregator.id}),
        connection(%{source_step_id: multiply.id, target_step_id: aggregator.id})
      ])
      |> compile!()
      |> elem(0)
      |> react(%{"left" => [1, 2], "right" => [3]})

    assert productions(workflow, aggregator.id) == [[[2, 30], [3, nil]]]
  end

  test "joining split branches across different depths defaults to zip_nil after collection" do
    root = step(%{id: Ecto.UUID.generate(), type_id: "manual_input", name: "Entry"})

    outer_splitter =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "splitter",
        name: "Outer Split",
        config: %{"field" => "outer"}
      })

    inner_splitter =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "splitter",
        name: "Inner Split",
        config: %{}
      })

    inner = math_step("Times Ten", "multiply", "{{ input }}", 10)
    outer = step(%{id: Ecto.UUID.generate(), type_id: "data_output", name: "Outer"})
    join = step(%{id: Ecto.UUID.generate(), type_id: "join", name: "Join", config: %{}})

    workflow =
      [root, outer_splitter, inner_splitter, inner, outer, join]
      |> version([
        connection(%{source_step_id: root.id, target_step_id: outer_splitter.id}),
        connection(%{source_step_id: outer_splitter.id, target_step_id: inner_splitter.id}),
        connection(%{source_step_id: inner_splitter.id, target_step_id: inner.id}),
        connection(%{source_step_id: outer_splitter.id, target_step_id: outer.id}),
        connection(%{source_step_id: inner.id, target_step_id: join.id}),
        connection(%{source_step_id: outer.id, target_step_id: join.id})
      ])
      |> compile!()
      |> elem(0)
      |> react(%{"outer" => [[1, 2], [3]]})

    assert productions(workflow, join.id) == [[[10, [1, 2]], [20, [3]], [30, nil]]]
  end

  test "aggregator implicitly zips different split depths after collecting branch outputs" do
    root = step(%{id: Ecto.UUID.generate(), type_id: "manual_input", name: "Entry"})

    outer_splitter =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "splitter",
        name: "Outer Split",
        config: %{"field" => "outer"}
      })

    inner_splitter =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "splitter",
        name: "Inner Split",
        config: %{}
      })

    inner = math_step("Times Ten", "multiply", "{{ input }}", 10)
    outer = step(%{id: Ecto.UUID.generate(), type_id: "data_output", name: "Outer"})

    aggregator =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "aggregator",
        name: "Collect",
        config: %{"operation" => "collect"}
      })

    workflow =
      [root, outer_splitter, inner_splitter, inner, outer, aggregator]
      |> version([
        connection(%{source_step_id: root.id, target_step_id: outer_splitter.id}),
        connection(%{source_step_id: outer_splitter.id, target_step_id: inner_splitter.id}),
        connection(%{source_step_id: inner_splitter.id, target_step_id: inner.id}),
        connection(%{source_step_id: outer_splitter.id, target_step_id: outer.id}),
        connection(%{source_step_id: inner.id, target_step_id: aggregator.id}),
        connection(%{source_step_id: outer.id, target_step_id: aggregator.id})
      ])
      |> compile!()
      |> elem(0)
      |> react(%{"outer" => [[1, 2], [3]]})

    assert productions(workflow, aggregator.id) == [[[10, [1, 2]], [20, [3]], [30, nil]]]
  end

  test "implicit multi-branch aggregators reject unsupported operations" do
    root = step(%{id: Ecto.UUID.generate(), type_id: "manual_input", name: "Entry"})

    left_splitter =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "splitter",
        name: "Split Left",
        config: %{"field" => "left"}
      })

    right_splitter =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "splitter",
        name: "Split Right",
        config: %{"field" => "right"}
      })

    aggregator =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "aggregator",
        name: "Sum",
        config: %{"operation" => "sum"}
      })

    version =
      version(
        [root, left_splitter, right_splitter, aggregator],
        [
          connection(%{source_step_id: root.id, target_step_id: left_splitter.id}),
          connection(%{source_step_id: root.id, target_step_id: right_splitter.id}),
          connection(%{source_step_id: left_splitter.id, target_step_id: aggregator.id}),
          connection(%{source_step_id: right_splitter.id, target_step_id: aggregator.id})
        ]
      )

    assert_compile_error(version, "only supports operations: collect, count, first, last")
  end

  defp split_collect_workflow do
    root = step(%{id: Ecto.UUID.generate(), type_id: "manual_input", name: "Entry"})

    splitter =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "splitter",
        name: "Split",
        config: %{"field" => "items"}
      })

    multiply = math_step("Times Two", "multiply", "{{ input }}", 2)

    aggregator =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "aggregator",
        name: "Collect",
        config: %{"operation" => "collect"}
      })

    workflow =
      [root, splitter, multiply, aggregator]
      |> version([
        connection(%{source_step_id: root.id, target_step_id: splitter.id}),
        connection(%{source_step_id: splitter.id, target_step_id: multiply.id}),
        connection(%{source_step_id: multiply.id, target_step_id: aggregator.id})
      ])
      |> compile!()
      |> elem(0)

    {workflow, aggregator.id}
  end

  defp math_step(name, operation, value, operand) do
    step(%{
      id: Ecto.UUID.generate(),
      type_id: "math",
      name: name,
      config: %{"operation" => operation, "value" => value, "operand" => operand}
    })
  end

  defp assert_compile_error(version, message_fragment) do
    assert {:error, errors} = Compiler.compile(version)
    assert Enum.any?(errors, &String.contains?(&1.message, message_fragment))
  end
end
