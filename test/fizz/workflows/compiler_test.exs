defmodule Fizz.Workflows.CompilerTest do
  use ExUnit.Case, async: true

  alias Fizz.Workflows.Compiler
  alias Fizz.Workflows.Compiler.Normalizer
  alias Fizz.Workflows.Expressions.AccessPlan
  alias Fizz.Workflows.WorkflowDefinitionVersion
  alias Fizz.Workflows.Embeds.{Connection, Step, StepGroup}
  alias Runic.Workflow

  test "compile builds a valid Runic workflow for a simple two-step definition" do
    version = simple_version()

    assert {:ok, %Runic.Workflow{} = workflow, compiled_hash} = Compiler.compile(version)
    assert is_binary(compiled_hash)
    assert Map.has_key?(workflow.components, hd(version.steps).id)
    assert Map.has_key?(workflow.components, List.last(version.steps).id)
    assert workflow.fizz_metadata.compiler_version == Compiler.compiler_version()

    productions =
      workflow
      |> Workflow.react_until_satisfied(%{"name" => "Ada"})
      |> Workflow.raw_productions()

    assert Enum.member?(productions, %{"name" => "Ada"})
  end

  test "ui-only edits produce the same compiled hash" do
    version = simple_version()

    ui_only_edited =
      %{
        version
        | viewport: %{"x" => 999, "y" => 555, "zoom" => 2.0},
          settings: %{"grid" => false}
      }
      |> put_in([Access.key!(:steps), Access.at(0), Access.key!(:position)], %{
        "x" => 999,
        "y" => 888
      })
      |> put_in([Access.key!(:steps), Access.at(0), Access.key!(:notes)], "editor note")
      |> Map.put(:step_groups, [
        %StepGroup{
          id: Ecto.UUID.generate(),
          name: "Group",
          color: "#fff",
          step_ids: Enum.map(version.steps, & &1.id)
        }
      ])

    assert {:ok, _workflow, first_hash} = Compiler.compile(version)
    assert {:ok, _workflow, second_hash} = Compiler.compile(ui_only_edited)
    assert first_hash == second_hash
  end

  test "execution-relevant edits produce different compiled hashes" do
    version = simple_version()

    changed =
      put_in(
        version,
        [Access.key!(:steps), Access.at(1), Access.key!(:config), Access.key("label")],
        "Changed"
      )

    assert {:ok, _workflow, first_hash} = Compiler.compile(version)
    assert {:ok, _workflow, second_hash} = Compiler.compile(changed)
    refute first_hash == second_hash
  end

  test "step groups are excluded from the normalized ir" do
    version =
      %{
        simple_version()
        | step_groups: [
            %StepGroup{
              id: Ecto.UUID.generate(),
              name: "Ignored",
              color: "#000",
              step_ids: Enum.map(simple_version().steps, & &1.id)
            }
          ]
      }

    assert {:ok, ir} = Normalizer.normalize(version)
    refute Map.has_key?(ir, :step_groups)
    refute Map.has_key?(ir, :viewport)
    refute Map.has_key?(ir, :settings)
  end

  test "expressions are precompiled into access plans" do
    version = expression_version()

    assert {:ok, workflow, _compiled_hash} = Compiler.compile(version)

    compiled_step = Workflow.get_component(workflow, List.last(version.steps).id)
    compiled_config = compiled_step.closure.bindings[:compiled_config]

    assert match?(%AccessPlan.ValueExpression{}, compiled_config["label"])
  end

  test "splitter fan-out and aggregator fan-in compile into runnable map/reduce semantics" do
    {version, ids} = map_reduce_version()

    assert {:ok, workflow, _compiled_hash} = Compiler.compile(version)
    assert %Runic.Workflow.Map{} = Workflow.get_component(workflow, ids.splitter)
    assert Workflow.get_component(workflow, ids.aggregator)

    workflow =
      workflow
      |> Workflow.plan_eagerly(%{"items" => [1, 2, 3]})
      |> Workflow.react_until_satisfied()

    assert 12 in Workflow.raw_productions(workflow, ids.aggregator)
  end

  test "condition connections route by authored output handle" do
    {version, ids} = condition_version()

    assert {:ok, workflow, _compiled_hash} = Compiler.compile(version)

    workflow =
      workflow
      |> Workflow.plan_eagerly(%{"flag" => true})
      |> Workflow.react_until_satisfied()

    assert [%{"flag" => true}] = Workflow.raw_productions(workflow, ids.true_step)
    assert [] = Workflow.raw_productions(workflow, ids.false_step)
  end

  test "switch connections route by authored output handle" do
    {version, ids} = switch_version()

    assert {:ok, workflow, _compiled_hash} = Compiler.compile(version)

    workflow =
      workflow
      |> Workflow.plan_eagerly(%{"status" => "active"})
      |> Workflow.react_until_satisfied()

    assert [%{"status" => "active"}] = Workflow.raw_productions(workflow, ids.active_step)
    assert [] = Workflow.raw_productions(workflow, ids.pending_step)
    assert [] = Workflow.raw_productions(workflow, ids.default_step)
  end

  test "multiple switch cases targeting the same output handle behave as a union, not a join" do
    {version, ids} = switch_union_version()

    assert {:ok, workflow, _compiled_hash} = Compiler.compile(version)

    workflow =
      workflow
      |> Workflow.plan_eagerly(%{"status" => "pending"})
      |> Workflow.react_until_satisfied()

    assert [%{"status" => "pending"}] = Workflow.raw_productions(workflow, ids.matched_step)
  end

  defp simple_version do
    entry_id = Ecto.UUID.generate()
    debug_id = Ecto.UUID.generate()

    %WorkflowDefinitionVersion{
      id: Ecto.UUID.generate(),
      steps: [
        %Step{
          id: entry_id,
          type_id: "manual_input",
          name: "Entry",
          config: %{},
          position: %{},
          notes: nil
        },
        %Step{
          id: debug_id,
          type_id: "debug",
          name: "Debug",
          config: %{"label" => "Hello"},
          position: %{},
          notes: nil
        }
      ],
      connections: [
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: entry_id,
          source_output: "main",
          target_step_id: debug_id,
          target_input: "main"
        }
      ],
      step_groups: [],
      viewport: %{"x" => 0, "y" => 0, "zoom" => 1.0},
      settings: %{}
    }
  end

  defp expression_version do
    version = simple_version()

    put_in(
      version,
      [Access.key!(:steps), Access.at(1), Access.key!(:config), Access.key("label")],
      "{{ input.name }}"
    )
  end

  defp map_reduce_version do
    entry_id = Ecto.UUID.generate()
    splitter_id = Ecto.UUID.generate()
    math_id = Ecto.UUID.generate()
    aggregator_id = Ecto.UUID.generate()

    version = %WorkflowDefinitionVersion{
      id: Ecto.UUID.generate(),
      steps: [
        %Step{
          id: entry_id,
          type_id: "manual_input",
          name: "Entry",
          config: %{},
          position: %{},
          notes: nil
        },
        %Step{
          id: splitter_id,
          type_id: "splitter",
          name: "Split",
          config: %{"field" => "items"},
          position: %{},
          notes: nil
        },
        %Step{
          id: math_id,
          type_id: "math",
          name: "Multiply",
          config: %{"operation" => "multiply", "value" => "{{ input }}", "operand" => 2},
          position: %{},
          notes: nil
        },
        %Step{
          id: aggregator_id,
          type_id: "aggregator",
          name: "Sum",
          config: %{"operation" => "sum"},
          position: %{},
          notes: nil
        }
      ],
      connections: [
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: entry_id,
          source_output: "main",
          target_step_id: splitter_id,
          target_input: "main"
        },
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: splitter_id,
          source_output: "main",
          target_step_id: math_id,
          target_input: "main"
        },
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: math_id,
          source_output: "main",
          target_step_id: aggregator_id,
          target_input: "main"
        }
      ],
      step_groups: [],
      viewport: %{},
      settings: %{}
    }

    {version, %{splitter: splitter_id, aggregator: aggregator_id}}
  end

  defp condition_version do
    entry_id = Ecto.UUID.generate()
    condition_id = Ecto.UUID.generate()
    true_id = Ecto.UUID.generate()
    false_id = Ecto.UUID.generate()

    version = %WorkflowDefinitionVersion{
      id: Ecto.UUID.generate(),
      steps: [
        %Step{
          id: entry_id,
          type_id: "manual_input",
          name: "Entry",
          config: %{},
          position: %{},
          notes: nil
        },
        %Step{
          id: condition_id,
          type_id: "condition",
          name: "Check Flag",
          config: %{
            "condition" => "{{ input.flag }}",
            "true_output" => "yes",
            "false_output" => "no"
          },
          position: %{},
          notes: nil
        },
        %Step{
          id: true_id,
          type_id: "debug",
          name: "True Branch",
          config: %{},
          position: %{},
          notes: nil
        },
        %Step{
          id: false_id,
          type_id: "debug",
          name: "False Branch",
          config: %{},
          position: %{},
          notes: nil
        }
      ],
      connections: [
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: entry_id,
          source_output: "main",
          target_step_id: condition_id,
          target_input: "main"
        },
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: condition_id,
          source_output: "yes",
          target_step_id: true_id,
          target_input: "main"
        },
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: condition_id,
          source_output: "no",
          target_step_id: false_id,
          target_input: "main"
        }
      ],
      step_groups: [],
      viewport: %{},
      settings: %{}
    }

    {version, %{true_step: true_id, false_step: false_id}}
  end

  defp switch_version do
    entry_id = Ecto.UUID.generate()
    switch_id = Ecto.UUID.generate()
    active_id = Ecto.UUID.generate()
    pending_id = Ecto.UUID.generate()
    default_id = Ecto.UUID.generate()

    version = %WorkflowDefinitionVersion{
      id: Ecto.UUID.generate(),
      steps: [
        %Step{
          id: entry_id,
          type_id: "manual_input",
          name: "Entry",
          config: %{},
          position: %{},
          notes: nil
        },
        %Step{
          id: switch_id,
          type_id: "switch",
          name: "Route Status",
          config: %{
            "value" => "{{ input.status }}",
            "cases" => [
              %{"match" => "active", "output" => "active"},
              %{"match" => "pending", "output" => "pending"}
            ],
            "default_output" => "other"
          },
          position: %{},
          notes: nil
        },
        %Step{
          id: active_id,
          type_id: "debug",
          name: "Active",
          config: %{},
          position: %{},
          notes: nil
        },
        %Step{
          id: pending_id,
          type_id: "debug",
          name: "Pending",
          config: %{},
          position: %{},
          notes: nil
        },
        %Step{
          id: default_id,
          type_id: "debug",
          name: "Default",
          config: %{},
          position: %{},
          notes: nil
        }
      ],
      connections: [
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: entry_id,
          source_output: "main",
          target_step_id: switch_id,
          target_input: "main"
        },
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: switch_id,
          source_output: "active",
          target_step_id: active_id,
          target_input: "main"
        },
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: switch_id,
          source_output: "pending",
          target_step_id: pending_id,
          target_input: "main"
        },
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: switch_id,
          source_output: "other",
          target_step_id: default_id,
          target_input: "main"
        }
      ],
      step_groups: [],
      viewport: %{},
      settings: %{}
    }

    {version, %{active_step: active_id, pending_step: pending_id, default_step: default_id}}
  end

  defp switch_union_version do
    entry_id = Ecto.UUID.generate()
    switch_id = Ecto.UUID.generate()
    matched_id = Ecto.UUID.generate()

    version = %WorkflowDefinitionVersion{
      id: Ecto.UUID.generate(),
      steps: [
        %Step{
          id: entry_id,
          type_id: "manual_input",
          name: "Entry",
          config: %{},
          position: %{},
          notes: nil
        },
        %Step{
          id: switch_id,
          type_id: "switch",
          name: "Route Status",
          config: %{
            "value" => "{{ input.status }}",
            "cases" => [
              %{"match" => "active", "output" => "matched"},
              %{"match" => "pending", "output" => "matched"}
            ],
            "default_output" => "other"
          },
          position: %{},
          notes: nil
        },
        %Step{
          id: matched_id,
          type_id: "debug",
          name: "Matched",
          config: %{},
          position: %{},
          notes: nil
        }
      ],
      connections: [
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: entry_id,
          source_output: "main",
          target_step_id: switch_id,
          target_input: "main"
        },
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: switch_id,
          source_output: "matched",
          target_step_id: matched_id,
          target_input: "main"
        }
      ],
      step_groups: [],
      viewport: %{},
      settings: %{}
    }

    {version, %{matched_step: matched_id}}
  end
end
