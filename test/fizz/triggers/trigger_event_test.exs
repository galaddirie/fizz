defmodule Fizz.Triggers.TriggerEventTest do
  use Fizz.DataCase, async: false

  import Fizz.WorkflowsFixtures

  alias Fizz.Repo
  alias Fizz.Triggers.{TriggerEvent, TriggerRegistration}
  alias Fizz.Workflows

  test "event dedup constraint prevents duplicate registration event ids" do
    scope = project_scope_fixture()
    %{definition: definition, draft: draft} = create_definition_fixture(scope)

    registration =
      %TriggerRegistration{}
      |> TriggerRegistration.changeset(%{
        user_id: scope.user.id,
        workflow_definition_id: definition.id,
        definition_version_id: draft.id,
        step_id: "manual-root",
        project_id: scope.project.id,
        workos_organization_id: scope.project.workos_organization_id,
        kind: "manual",
        status: "active",
        registration_params: %{},
        config_digest: "digest-a"
      })
      |> Repo.insert!()

    attrs = %{
      trigger_registration_id: registration.id,
      project_id: scope.project.id,
      workos_organization_id: scope.project.workos_organization_id,
      event_id: "evt-1",
      event_data: %{"hello" => "world"},
      status: "pending"
    }

    assert {:ok, _event} =
             %TriggerEvent{}
             |> TriggerEvent.changeset(attrs)
             |> Repo.insert()

    assert {:error, changeset} =
             %TriggerEvent{}
             |> TriggerEvent.changeset(attrs)
             |> Repo.insert()

    assert "has already been taken" in errors_on(changeset).trigger_registration_id
  end

  defp create_definition_fixture(scope) do
    {:ok, %{definition: definition, draft: draft}} =
      Workflows.create_definition(scope, %{
        name: "Trigger Event #{System.unique_integer([:positive])}",
        description: "Event test"
      })

    %{definition: definition, draft: draft}
  end
end
