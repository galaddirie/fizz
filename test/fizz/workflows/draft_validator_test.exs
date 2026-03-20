defmodule Fizz.Workflows.DraftValidatorTest do
  use Fizz.DataCase, async: false

  alias Fizz.Workflows.DraftValidator
  alias Fizz.Workflows.DraftValidator.ValidationError
  alias Fizz.Workflows.Embeds.{Connection, Step, StepGroup}
  alias Fizz.Workflows.WorkflowDefinitionVersion
  alias Fizz.WorkflowsFixtures

  test "validate_for_publish catches missing required fields" do
    scope = WorkflowsFixtures.project_scope_fixture()
    http_step = WorkflowsFixtures.step(%{type_id: "http_request", config: %{}})

    version =
      version_from_snapshot(
        WorkflowsFixtures.snapshot_attrs(%{
          steps: [http_step]
        })
      )

    assert {:error, errors} = DraftValidator.validate_for_publish(version, scope)

    assert Enum.any?(errors, fn
             %ValidationError{
               code: :missing_required_field,
               step_id: step_id,
               field: "url",
               message: "is required"
             } ->
               step_id == http_step.id

             _ ->
               false
           end)
  end

  test "validate_for_publish catches invalid expressions" do
    scope = WorkflowsFixtures.project_scope_fixture()

    debug_step =
      WorkflowsFixtures.step(%{
        type_id: "debug",
        config: %{"label" => "{{ input.name | concat: \"!\" }}"}
      })

    version =
      version_from_snapshot(
        WorkflowsFixtures.snapshot_attrs(%{
          steps: [debug_step]
        })
      )

    assert {:error, errors} = DraftValidator.validate_for_publish(version, scope)

    assert Enum.any?(errors, fn
             %ValidationError{
               code: :invalid_expression,
               step_id: step_id,
               field: "label",
               message: message
             } ->
               step_id == debug_step.id and String.contains?(message, "unsupported filter")

             _ ->
               false
           end)
  end

  test "validate_for_publish catches cycle" do
    scope = WorkflowsFixtures.project_scope_fixture()
    first_step = WorkflowsFixtures.step(%{type_id: "debug", name: "First"})
    second_step = WorkflowsFixtures.step(%{type_id: "debug", name: "Second"})

    version =
      version_from_snapshot(
        WorkflowsFixtures.snapshot_attrs(%{
          steps: [first_step, second_step],
          connections: [
            WorkflowsFixtures.connection(%{
              source_step_id: first_step.id,
              target_step_id: second_step.id
            }),
            WorkflowsFixtures.connection(%{
              source_step_id: second_step.id,
              target_step_id: first_step.id
            })
          ]
        })
      )

    assert {:error, errors} = DraftValidator.validate_for_publish(version, scope)

    assert Enum.any?(errors, fn
             %ValidationError{code: :cycle_detected, step_id: nil, message: message} ->
               String.contains?(message, "creates a cycle")

             _ ->
               false
           end)
  end

  test "validate_for_publish returns :ok for a valid draft" do
    scope = WorkflowsFixtures.project_scope_fixture()
    version = version_from_snapshot(WorkflowsFixtures.valid_snapshot_attrs())

    assert :ok = DraftValidator.validate_for_publish(version, scope)
  end

  defp version_from_snapshot(snapshot_attrs) do
    %WorkflowDefinitionVersion{
      id: Ecto.UUID.generate(),
      workflow_definition_id: Ecto.UUID.generate(),
      version: 1,
      status: :draft,
      steps: Enum.map(snapshot_attrs.steps || [], &struct(Step, &1)),
      connections: Enum.map(snapshot_attrs.connections || [], &struct(Connection, &1)),
      step_groups: Enum.map(snapshot_attrs.step_groups || [], &struct(StepGroup, &1)),
      viewport: snapshot_attrs.viewport || %{},
      settings: snapshot_attrs.settings || %{}
    }
  end
end
