defmodule Fizz.Runtime.RunicAdapterTest do
  use ExUnit.Case, async: true

  alias Fizz.Accounts.Scope
  alias Runic.Component
  alias Runic.Workflow
  alias Fizz.Runtime.Hooks.Observability
  alias Fizz.Runtime.RunicAdapter
  alias Fizz.Workflows.Embeds.Connection
  alias Fizz.Workflows.Embeds.Step

  describe "splitter fan-out execution" do
    test "runs downstream steps per item and aggregates all items" do
      source =
        workflow_source(
          [
            step("splitter", "splitter", %{"field" => "items"}),
            step("debug_item", "debug", %{"label" => "Item", "level" => "info"}),
            step("aggregate", "aggregator", %{"operation" => "collect"})
          ],
          [
            connection("c1", "splitter", "debug_item"),
            connection("c2", "debug_item", "aggregate")
          ]
        )

      outputs = run_workflow(source, %{"items" => [1, 2, 3]})

      assert Enum.sort(outputs["aggregate"]) == [1, 2, 3]
      assert outputs["debug_item"] in [1, 2, 3]
    end
  end

  describe "aggregator mode selection" do
    test "uses reduce only for aggregators in the active fan-out path" do
      source =
        workflow_source(
          [
            step("splitter", "splitter", %{"field" => "items"}),
            step("debug_item", "debug", %{"label" => "Item", "level" => "info"}),
            step("aggregate_in_fanout", "aggregator", %{"operation" => "collect"}),
            step("debug_after_fanout", "debug", %{"label" => "After", "level" => "info"}),
            step("aggregate_after_fanout", "aggregator", %{"operation" => "count"})
          ],
          [
            connection("c1", "splitter", "debug_item"),
            connection("c2", "debug_item", "aggregate_in_fanout"),
            connection("c3", "aggregate_in_fanout", "debug_after_fanout"),
            connection("c4", "debug_after_fanout", "aggregate_after_fanout")
          ]
        )

      workflow = RunicAdapter.to_runic_workflow(source, execution_id: "exec_test")

      assert match?(
               %Runic.Workflow.Reduce{},
               Workflow.get_component!(workflow, "aggregate_in_fanout")
             )

      refute match?(
               %Runic.Workflow.Reduce{},
               Workflow.get_component!(workflow, "aggregate_after_fanout")
             )

      outputs = run_workflow(source, %{"items" => [1, 2, 3]})
      assert outputs["aggregate_after_fanout"] == 3
    end
  end

  describe "fan-out aware join mapping" do
    test "maps each parent to its nearest splitter in join fan_out_sources" do
      source =
        workflow_source(
          [
            step("splitter_a", "splitter", %{"field" => "items_a"}),
            step("splitter_b", "splitter", %{"field" => "items_b"}),
            step("debug_a", "debug", %{"label" => "A", "level" => "info"}),
            step("debug_b", "debug", %{"label" => "B", "level" => "info"}),
            step("joined_debug", "debug", %{"label" => "Joined", "level" => "info"})
          ],
          [
            connection("c1", "splitter_a", "debug_a"),
            connection("c2", "splitter_b", "debug_b"),
            connection("c3", "debug_a", "joined_debug"),
            connection("c4", "debug_b", "joined_debug")
          ]
        )

      workflow = RunicAdapter.to_runic_workflow(source, execution_id: "exec_test")

      [join] =
        workflow.graph
        |> Graph.vertices()
        |> Enum.filter(&match?(%Runic.Workflow.Join{}, &1))

      splitter_a = Workflow.get_component!(workflow, "splitter_a")
      splitter_b = Workflow.get_component!(workflow, "splitter_b")
      debug_a = Workflow.get_component!(workflow, "debug_a")
      debug_b = Workflow.get_component!(workflow, "debug_b")

      assert join.fan_out_sources[Component.hash(debug_a)] == Component.hash(splitter_a)
      assert join.fan_out_sources[Component.hash(debug_b)] == Component.hash(splitter_b)
    end
  end

  describe "subnode slot wiring" do
    test "builds and runs ai_agent with prompt/model slot connections" do
      source =
        workflow_source(
          [
            step("ai_prompt_template", "ai_prompt_template", %{
              "system_prompt" => "You are a helpful assistant.",
              "user_prompt" => "Hello from test",
              "context" => %{}
            }),
            step("openai_model", "openai_model", %{
              "model" => "gpt-4.1-mini",
              "temperature" => 0.2,
              "max_tokens" => 400,
              "credential_ref" => %{
                "id" => "cred_openai",
                "provider" => "openai_api_key",
                "auth_type" => "api_key",
                "owner_user_id" => "user_123"
              }
            }),
            step("ai_agent", "ai_agent", %{"mode" => "assemble_only"}),
            step("debug_after", "debug", %{"label" => "After", "level" => "info"})
          ],
          [
            slot_connection("c1", "ai_prompt_template", "ai_agent", "prompt"),
            slot_connection("c2", "openai_model", "ai_agent", "model"),
            connection("c3", "ai_agent", "debug_after")
          ]
        )

      outputs = run_workflow(source, %{"name" => "John"})

      assert is_map(outputs["ai_agent"])
      assert outputs["ai_agent"]["provider"] == "openai_api_key"
      assert outputs["ai_agent"]["model"] == "gpt-4.1-mini"
      assert is_list(outputs["ai_agent"]["messages"])
      assert outputs["debug_after"] == outputs["ai_agent"]
    end
  end

  describe "execution scope propagation" do
    test "passes scope option into step runner opts" do
      source =
        workflow_source(
          [step("debug_step", "debug", %{"label" => "Debug", "level" => "info"})],
          []
        )

      scope = %Scope{organization_id: "org_test"}
      workflow = RunicAdapter.to_runic_workflow(source, execution_id: "exec_test", scope: scope)
      component = Workflow.get_component!(workflow, "debug_step")

      assert {:env, [_step, opts]} = :erlang.fun_info(component.work, :env)
      assert Keyword.get(opts, :scope) == scope
    end
  end

  defp run_workflow(source, input) do
    reset_runtime_process_state()

    try do
      source
      |> RunicAdapter.to_runic_workflow(execution_id: "exec_test")
      |> Observability.attach_all_hooks(
        execution_id: "exec_test",
        workflow_id: source.id,
        skip_production_init: true
      )
      |> Workflow.react_until_satisfied(input)

      Process.get(:fizz_accumulated_outputs, %{})
    after
      reset_runtime_process_state()
    end
  end

  defp reset_runtime_process_state do
    keys = [
      :fizz_accumulated_outputs,
      :fizz_step_outputs,
      :fizz_step_skipped,
      :fizz_fan_out_context,
      :fizz_step_events
    ]

    Enum.each(keys, &Process.delete/1)
  end

  defp workflow_source(steps, connections) do
    %{
      id: "wf_test",
      steps: steps,
      connections: connections,
      groups: []
    }
  end

  defp step(id, type_id, config) do
    %Step{
      id: id,
      type_id: type_id,
      name: id,
      config: config,
      position: %{}
    }
  end

  defp connection(id, source_step_id, target_step_id) do
    %Connection{
      id: id,
      source_step_id: source_step_id,
      source_output: "main",
      target_step_id: target_step_id,
      target_input: "main"
    }
  end

  defp slot_connection(id, source_step_id, target_step_id, target_input) do
    %Connection{
      id: id,
      source_step_id: source_step_id,
      source_output: "main",
      target_step_id: target_step_id,
      target_input: target_input
    }
  end
end
