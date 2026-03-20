defmodule Fizz.Triggers.TriggerRegistrationTest do
  use Fizz.DataCase, async: false

  import Fizz.WorkflowsFixtures

  alias Fizz.Repo
  alias Fizz.Triggers.TriggerRegistration
  alias Fizz.Workflows
  alias Fizz.Workflows.WorkflowRun

  test "changeset validates required fields" do
    changeset = TriggerRegistration.changeset(%TriggerRegistration{}, %{})

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).workflow_definition_id
    assert "can't be blank" in errors_on(changeset).definition_version_id
    assert "can't be blank" in errors_on(changeset).project_id
    assert "can't be blank" in errors_on(changeset).step_id
    assert "can't be blank" in errors_on(changeset).kind
    assert "can't be blank" in errors_on(changeset).config_digest
  end

  test "definition-level dedup constraint prevents duplicate registrations" do
    scope = project_scope_fixture()
    %{definition: definition, draft: draft} = create_definition_fixture(scope)

    attrs = registration_attrs(scope, definition, draft, %{step_id: "manual-root"})

    assert {:ok, _registration} =
             %TriggerRegistration{}
             |> TriggerRegistration.changeset(attrs)
             |> Repo.insert()

    assert {:error, changeset} =
             %TriggerRegistration{}
             |> TriggerRegistration.changeset(Map.put(attrs, :config_digest, "changed"))
             |> Repo.insert()

    assert "has already been taken" in errors_on(changeset).definition_version_id
  end

  test "run-level dedup constraint prevents duplicate registrations" do
    scope = project_scope_fixture()
    %{definition: definition, draft: draft} = create_definition_fixture(scope)
    run = insert_run(scope, definition, draft)

    attrs =
      scope
      |> registration_attrs(definition, draft, %{step_id: "wait-for-signal", run_id: run.id})
      |> Map.delete(:definition_version_id)

    attrs = Map.put(attrs, :definition_version_id, draft.id)

    assert {:ok, _registration} =
             %TriggerRegistration{}
             |> TriggerRegistration.changeset(attrs)
             |> Repo.insert()

    assert {:error, changeset} =
             %TriggerRegistration{}
             |> TriggerRegistration.changeset(Map.put(attrs, :config_digest, "changed"))
             |> Repo.insert()

    assert "has already been taken" in errors_on(changeset).run_id
  end

  test "webhook path unique constraint enforced for active registrations" do
    scope = project_scope_fixture()
    %{definition: definition, draft: draft} = create_definition_fixture(scope)
    webhook_path = "wh_test_#{System.unique_integer([:positive])}"

    first_attrs =
      registration_attrs(scope, definition, draft, %{
        step_id: "webhook-a",
        kind: "webhook",
        webhook_path: webhook_path,
        webhook_secret: "secret-a"
      })

    second_attrs =
      registration_attrs(scope, definition, draft, %{
        step_id: "webhook-b",
        kind: "webhook",
        webhook_path: webhook_path,
        webhook_secret: "secret-b"
      })

    assert {:ok, _registration} =
             %TriggerRegistration{}
             |> TriggerRegistration.changeset(first_attrs)
             |> Repo.insert()

    assert {:error, changeset} =
             %TriggerRegistration{}
             |> TriggerRegistration.changeset(second_attrs)
             |> Repo.insert()

    assert "has already been taken" in errors_on(changeset).webhook_path
  end

  defp create_definition_fixture(scope) do
    {:ok, %{definition: definition, draft: draft}} =
      Workflows.create_definition(scope, %{
        name: "Trigger Test #{System.unique_integer([:positive])}",
        description: "Registration test"
      })

    %{definition: definition, draft: draft}
  end

  defp insert_run(scope, definition, draft) do
    %WorkflowRun{}
    |> WorkflowRun.changeset(%{
      workflow_definition_id: definition.id,
      workflow_definition_version_id: draft.id,
      project_id: scope.project.id,
      workos_organization_id: scope.project.workos_organization_id,
      status: :pending,
      input: %{},
      last_active_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp registration_attrs(scope, definition, draft, overrides) do
    Map.merge(
      %{
        workflow_definition_id: definition.id,
        definition_version_id: draft.id,
        step_id: "step-#{System.unique_integer([:positive])}",
        project_id: scope.project.id,
        workos_organization_id: scope.project.workos_organization_id,
        kind: "manual",
        status: "active",
        registration_params: %{},
        config_digest: "digest-#{System.unique_integer([:positive])}"
      },
      overrides
    )
  end
end
