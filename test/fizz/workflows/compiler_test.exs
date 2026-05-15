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

  test "credential slot steps request runtime auth context" do
    append_id = Ecto.UUID.generate()

    version = %WorkflowDefinitionVersion{
      id: Ecto.UUID.generate(),
      steps: [
        %Step{
          id: append_id,
          type_id: "google_sheets_append_row",
          name: "Append Row",
          config: %{
            "credential_ref" => credential_slot("google_oauth", "oauth"),
            "spreadsheet_id" => "sheet_123",
            "values" => %{"A" => "1"}
          },
          position: %{},
          notes: nil
        }
      ],
      connections: [],
      step_groups: [],
      viewport: %{},
      settings: %{}
    }

    assert {:ok, workflow, _compiled_hash} = Compiler.compile(version)

    context_keys =
      workflow
      |> Workflow.get_component(append_id)
      |> Map.fetch!(:meta_refs)
      |> Enum.filter(&(&1.kind == :context))
      |> Enum.map(& &1.context_key)

    assert :current_scope in context_keys
    assert :user_id in context_keys
    assert :project_id in context_keys
    assert :workos_organization_id in context_keys
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

  test "root steps assemble input-connected subnodes into runnable input payloads" do
    {version, ids} = ai_agent_version()
    expected_schema = ai_agent_response_schema()

    assert {:ok, workflow, _compiled_hash} = Compiler.compile(version)
    assert {:ok, context_keys} = Map.fetch(Workflow.required_context_keys(workflow), ids.agent)
    assert {:current_scope, :required} in context_keys

    workflow =
      workflow
      |> Workflow.plan_eagerly(%{"name" => "Ada Lovelace", "topic" => "algebra"})
      |> Workflow.react_until_satisfied()

    [output] = Workflow.raw_productions(workflow, ids.agent)

    assert output["_primary"] == %{"name" => "Ada Lovelace", "topic" => "algebra"}
    assert output["provider"] == "openai_api_key"
    assert output["model"] == "gpt-5.5"

    assert output["messages"] == [
             %{"role" => "system", "content" => "Solve carefully."},
             %{"role" => "user", "content" => "Hello Ada Lovelace"}
           ]

    assert output["structured_schema"] == %{
             "name" => "agent_response",
             "json_schema" => expected_schema,
             "strict" => true
           }

    assert output["response_format"] == %{
             "type" => "json_schema",
             "json_schema" => %{
               "name" => "agent_response",
               "schema" => expected_schema,
               "strict" => true
             }
           }

    assert output["tools"] == [
             %{
               "type" => "http",
               "name" => "lookup_user",
               "description" => "",
               "request" => %{
                 "method" => "GET",
                 "url" => "https://example.com/users/ada-lovelace",
                 "headers" => %{}
               }
             }
           ]
  end

  test "compile rejects root steps missing required subnode inputs" do
    version = missing_required_subnode_input_version()

    assert {:error, [%{message: message}]} = Compiler.compile(version)
    assert message =~ "missing required subnode input `model`"
  end

  test "compile rejects subnodes whose type does not match the target input" do
    version = invalid_subnode_input_type_version()

    assert {:error, [%{message: message}]} = Compiler.compile(version)
    assert message =~ "subnode input `model`"
    assert message =~ "got `ai_tool_http`"
  end

  test "compile rejects unattached subnodes" do
    version = unattached_subnode_version()

    assert {:error, [%{message: message}]} = Compiler.compile(version)
    assert message =~ "must be connected to a root input"
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

  defp ai_agent_version do
    entry_id = Ecto.UUID.generate()
    agent_id = Ecto.UUID.generate()
    model_id = Ecto.UUID.generate()
    schema_id = Ecto.UUID.generate()
    tool_id = Ecto.UUID.generate()

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
          id: agent_id,
          type_id: "ai_agent",
          name: "Agent",
          config: %{
            "mode" => "assemble_only",
            "system_prompt" => "Solve carefully.",
            "user_message" => "Hello {{ input.name }}"
          },
          position: %{},
          notes: nil
        },
        %Step{
          id: model_id,
          type_id: "openai_model",
          name: "Model",
          config: %{
            "credential_ref" => credential_ref("openai_api_key"),
            "model" => "gpt-5.5",
            "temperature" => 0.3,
            "max_tokens" => 300
          },
          position: %{},
          notes: nil
        },
        %Step{
          id: schema_id,
          type_id: "ai_structure_schema",
          name: "Structure Schema",
          config: %{
            "name" => "agent_response",
            "json_schema" => ai_agent_response_schema(),
            "strict" => true
          },
          position: %{},
          notes: nil
        },
        %Step{
          id: tool_id,
          type_id: "ai_tool_http",
          name: "Tool",
          config: %{
            "name" => "lookup_user",
            "method" => "GET",
            "url" => "https://example.com/users/{{ input.name | slugify }}"
          },
          position: %{},
          notes: nil
        }
      ],
      connections: [
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: entry_id,
          source_output: "main",
          target_step_id: agent_id,
          target_input: "main"
        },
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: model_id,
          source_output: "main",
          target_step_id: agent_id,
          target_input: "model"
        },
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: schema_id,
          source_output: "main",
          target_step_id: agent_id,
          target_input: "structured_schema"
        },
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: tool_id,
          source_output: "main",
          target_step_id: agent_id,
          target_input: "tools"
        }
      ],
      step_groups: [],
      viewport: %{},
      settings: %{}
    }

    {version, %{agent: agent_id}}
  end

  defp missing_required_subnode_input_version do
    entry_id = Ecto.UUID.generate()
    agent_id = Ecto.UUID.generate()

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
          id: agent_id,
          type_id: "ai_agent",
          name: "Agent",
          config: %{"user_message" => "{{ json }}"},
          position: %{},
          notes: nil
        }
      ],
      connections: [
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: entry_id,
          source_output: "main",
          target_step_id: agent_id,
          target_input: "main"
        }
      ],
      step_groups: [],
      viewport: %{},
      settings: %{}
    }
  end

  defp invalid_subnode_input_type_version do
    entry_id = Ecto.UUID.generate()
    agent_id = Ecto.UUID.generate()
    tool_id = Ecto.UUID.generate()

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
          id: agent_id,
          type_id: "ai_agent",
          name: "Agent",
          config: %{},
          position: %{},
          notes: nil
        },
        %Step{
          id: tool_id,
          type_id: "ai_tool_http",
          name: "Tool",
          config: %{"name" => "wrong_slot", "url" => "https://example.com"},
          position: %{},
          notes: nil
        }
      ],
      connections: [
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: entry_id,
          source_output: "main",
          target_step_id: agent_id,
          target_input: "main"
        },
        %Connection{
          id: Ecto.UUID.generate(),
          source_step_id: tool_id,
          source_output: "main",
          target_step_id: agent_id,
          target_input: "model"
        }
      ],
      step_groups: [],
      viewport: %{},
      settings: %{}
    }
  end

  defp unattached_subnode_version do
    entry_id = Ecto.UUID.generate()
    model_id = Ecto.UUID.generate()
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
          config: %{},
          position: %{},
          notes: nil
        },
        %Step{
          id: model_id,
          type_id: "openai_model",
          name: "Model",
          config: %{"credential_ref" => credential_ref("openai_api_key")},
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
      viewport: %{},
      settings: %{}
    }
  end

  defp credential_ref(provider) do
    %{
      "id" => Ecto.UUID.generate(),
      "provider" => provider,
      "auth_type" => "api_key",
      "owner_user_id" => "user_123"
    }
  end

  defp credential_slot(provider, auth_type) do
    %{
      "$slot" => true,
      "kind" => "credential",
      "slot_key" => "auth",
      "spec" => %{"provider" => provider, "auth_type" => auth_type}
    }
  end

  defp ai_agent_response_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "answer" => %{"type" => "string"}
      },
      "required" => ["answer"]
    }
  end
end
