defmodule Fizz.Workflows.Compiler.ScopePlannerTest do
  use ExUnit.Case, async: true

  alias Fizz.Workflows.Compiler.ScopePlanner

  describe "plan!/3" do
    test "plans split-aware join defaults and parent contexts" do
      root = step("root", "manual_input")
      splitter = step("splitter", "splitter")
      add = step("add", "math")
      whole = step("whole", "data_output")
      join = step("join", "join")

      scopes =
        ScopePlanner.plan!(
          ~w(root splitter add whole join),
          steps([root, splitter, add, whole, join]),
          connection_indexes([
            connection("root", "splitter"),
            connection("splitter", "add"),
            connection("root", "whole"),
            connection("add", "join"),
            connection("whole", "join")
          ])
        )

      assert scopes["root"].outgoing_lineage == []
      assert scopes["splitter"].outgoing_lineage == ["splitter"]
      assert scopes["add"].outgoing_lineage == ["splitter"]
      assert scopes["whole"].outgoing_lineage == []

      assert scopes["join"].join_mode == "zip_nil"
      assert scopes["join"].join_has_split?
      assert scopes["join"].outgoing_lineage == []

      assert [
               %{source_step_id: "add", lineage: ["splitter"]},
               %{source_step_id: "whole", lineage: []}
             ] = scopes["join"].parent_contexts
    end

    test "rejects implicit split convergence without a join or aggregator" do
      root = step("root", "manual_input")
      splitter = step("splitter", "splitter")
      add = step("add", "math")
      multiply = step("multiply", "math")
      sink = step("sink", "data_output")

      assert_raise ArgumentError, ~r/insert an explicit `join` step/, fn ->
        ScopePlanner.plan!(
          ~w(root splitter add multiply sink),
          steps([root, splitter, add, multiply, sink]),
          connection_indexes([
            connection("root", "splitter"),
            connection("splitter", "add"),
            connection("splitter", "multiply"),
            connection("add", "sink"),
            connection("multiply", "sink")
          ])
        )
      end
    end
  end

  defp step(id, type_id), do: %{id: id, type_id: type_id, compiled_config: %{}}

  defp steps(steps), do: Map.new(steps, &{&1.id, &1})

  defp connection(source_step_id, target_step_id) do
    %{source_step_id: source_step_id, target_step_id: target_step_id}
  end

  defp connection_indexes(connections) do
    Enum.reduce(
      connections,
      %{incoming: %{}, outgoing: %{}, source_step_ids: MapSet.new()},
      fn connection, indexes ->
        %{
          incoming:
            Map.update(
              indexes.incoming,
              connection.target_step_id,
              [connection],
              &[
                connection | &1
              ]
            ),
          outgoing:
            Map.update(
              indexes.outgoing,
              connection.source_step_id,
              [connection],
              &[
                connection | &1
              ]
            ),
          source_step_ids: MapSet.put(indexes.source_step_ids, connection.source_step_id)
        }
      end
    )
  end
end
