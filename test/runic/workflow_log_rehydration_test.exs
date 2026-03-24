defmodule Runic.WorkflowLogRehydrationTest do
  use ExUnit.Case, async: false

  alias Runic.Runner
  alias Runic.Runner.Store.ETS, as: ETSStore
  alias Runic.Workflow
  alias Runic.Workflow.Events.{FanOutFactEmitted, FactProduced}
  alias Runic.Workflow.{Fact, FactRef, FactResolver, Rehydration}

  require Runic

  test "lean replay keeps FactProduced metadata on FactRef and resolve_hot restores it" do
    runner_name = unique_runner_name()
    start_supervised!({ETSStore, runner_name: runner_name})
    {:ok, store_state} = ETSStore.init_store(runner_name: runner_name)

    workflow =
      Runic.workflow(
        name: :echo_workflow,
        steps: [Runic.step(fn item -> item end, name: :echo)]
      )

    %{echo: echo_step} = Workflow.components(workflow)
    output_hash = System.unique_integer([:positive])

    events =
      Workflow.build_log(workflow) ++
        [
          %FactProduced{
            hash: output_hash,
            value: nil,
            ancestry: {echo_step.hash, System.unique_integer([:positive])},
            producer_label: :produced,
            weight: 1,
            meta: %{item_index: 0, items_total: 3}
          }
        ]

    lean_workflow = Workflow.from_events(events, nil, fact_mode: :ref)

    assert %FactRef{meta: %{item_index: 0, items_total: 3}} =
             Map.fetch!(lean_workflow.graph.vertices, output_hash)

    assert :ok = ETSStore.save_fact(output_hash, "value", store_state)

    resolver = FactResolver.new({ETSStore, store_state})

    {rehydrated_workflow, _resolver} =
      Rehydration.resolve_hot(lean_workflow, MapSet.new([output_hash]), resolver)

    assert %Fact{value: "value", meta: %{item_index: 0, items_total: 3}} =
             Map.fetch!(rehydrated_workflow.graph.vertices, output_hash)
  end

  test "runner workflow logs emit per-item fan-out entries and snapshot replay preserves them" do
    runner = start_runner!()
    workflow_id = unique_workflow_id()

    run_to_completion(runner, workflow_id, split_echo_workflow(), [1, 2, 3])

    fan_out_events = fan_out_events(runner, workflow_id)

    assert Enum.map(fan_out_events, & &1.emitted_value) == [1, 2, 3]
    assert Enum.map(fan_out_events, & &1.item_index) == [0, 1, 2]
    assert Enum.map(fan_out_events, & &1.items_total) == [3, 3, 3]
    assert fan_out_events |> Enum.map(& &1.emitted_fact_hash) |> Enum.uniq() |> length() == 3

    assert {:ok, live_workflow} = Runner.get_workflow(runner, workflow_id)

    Enum.each(fan_out_events, fn event ->
      assert_fact_vertex(
        Map.fetch!(live_workflow.graph.vertices, event.emitted_fact_hash),
        event.emitted_value,
        event.item_index,
        event.items_total
      )
    end)

    restored_workflow =
      live_workflow
      |> Workflow.event_log()
      |> Workflow.from_events()

    Enum.each(fan_out_events, fn event ->
      assert_fact_vertex(
        Map.fetch!(restored_workflow.graph.vertices, event.emitted_fact_hash),
        event.emitted_value,
        event.item_index,
        event.items_total
      )
    end)
  end

  test "runner resume rehydrates duplicate fan-out items with distinct hashes and metadata" do
    runner = start_runner!()
    workflow_id = unique_workflow_id()

    run_to_completion(runner, workflow_id, split_echo_workflow(), [1, 1, 1])

    fan_out_events = fan_out_events(runner, workflow_id)

    assert Enum.map(fan_out_events, & &1.emitted_value) == [1, 1, 1]
    assert Enum.map(fan_out_events, & &1.item_index) == [0, 1, 2]
    assert fan_out_events |> Enum.map(& &1.emitted_fact_hash) |> Enum.uniq() |> length() == 3

    assert :ok = Runner.stop(runner, workflow_id)
    assert {:ok, _pid} = Runner.resume(runner, workflow_id, rehydration: :full)
    assert {:ok, workflow} = Runner.get_workflow(runner, workflow_id)

    Enum.each(fan_out_events, fn event ->
      assert_fact_vertex(
        Map.fetch!(workflow.graph.vertices, event.emitted_fact_hash),
        event.emitted_value,
        event.item_index,
        event.items_total
      )
    end)
  end

  test "workflow log replay preserves split reduce aggregate outputs" do
    runner = start_runner!()
    workflow_id = unique_workflow_id()
    base_workflow = split_collect_workflow()

    run_to_completion(runner, workflow_id, base_workflow, [1, 2, 3])

    assert {:ok, live_workflow} = Runner.get_workflow(runner, workflow_id)
    assert Workflow.raw_productions(live_workflow, :collect) == [[11, 12, 13]]

    restored_workflow =
      live_workflow
      |> Workflow.event_log()
      |> Workflow.from_events()

    assert Workflow.raw_productions(restored_workflow, :collect) == [[11, 12, 13]]

    restored_from_base =
      live_workflow
      |> Workflow.event_log()
      |> Workflow.from_events(base_workflow)

    assert Workflow.raw_productions(restored_from_base, :collect) == [[11, 12, 13]]
  end

  defp split_echo_workflow do
    Runic.workflow(
      name: :split_echo,
      steps: [
        {Runic.map(fn item -> item end, name: :split),
         [Runic.step(fn item -> item end, name: :echo)]}
      ]
    )
  end

  defp split_collect_workflow do
    map_op = Runic.map(fn item -> item + 10 end, name: :split)
    reduce_op = Runic.reduce([], fn item, acc -> acc ++ [item] end, name: :collect, map: :split)

    Workflow.new(name: :split_collect)
    |> Workflow.add(map_op)
    |> Workflow.add(reduce_op, to: :split)
  end

  defp start_runner! do
    runner = unique_runner_name()
    start_supervised!({Runner, name: runner, store: ETSStore})
    runner
  end

  defp run_to_completion(runner, workflow_id, workflow, input) do
    parent = self()

    assert {:ok, _pid} =
             Runner.start_workflow(runner, workflow_id, workflow,
               on_complete: fn completed_workflow_id, _workflow ->
                 send(parent, {:workflow_complete, completed_workflow_id})
               end
             )

    assert :ok = Runner.run(runner, workflow_id, input)
    assert_receive {:workflow_complete, ^workflow_id}, 2_000
  end

  defp fan_out_events(runner, workflow_id) do
    runner
    |> stream_events(workflow_id)
    |> Enum.filter(&match?(%FanOutFactEmitted{}, &1))
    |> Enum.sort_by(& &1.item_index)
  end

  defp stream_events(runner, workflow_id) do
    {store_mod, store_state} = Runner.get_store(runner)
    assert {:ok, stream} = store_mod.stream(workflow_id, store_state)
    Enum.to_list(stream)
  end

  defp assert_fact_vertex(
         %Fact{value: value, meta: meta},
         expected_value,
         expected_index,
         expected_total
       ) do
    assert value == expected_value
    assert Map.get(meta, :item_index) == expected_index
    assert Map.get(meta, :items_total) == expected_total
  end

  defp unique_runner_name do
    Module.concat([__MODULE__, "Runner#{System.unique_integer([:positive])}"])
  end

  defp unique_workflow_id do
    "workflow-#{System.unique_integer([:positive])}"
  end
end
