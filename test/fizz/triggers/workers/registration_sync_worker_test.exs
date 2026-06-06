defmodule Fizz.Triggers.Workers.RegistrationSyncWorkerTest do
  use Fizz.DataCase, async: false
  use Oban.Testing, repo: Fizz.Repo

  import Ecto.Query
  import Fizz.WorkflowsFixtures

  alias Fizz.Repo
  alias Fizz.Triggers.TriggerRegistration
  alias Fizz.Triggers.Workers.RegistrationSyncWorker
  alias Fizz.Triggers.Workers.TriggerFireWorker
  alias Fizz.Workflows
  alias Fizz.Workflows.WorkflowDefinitionVersion

  test "creates missing registrations for published versions" do
    scope = project_scope_fixture()
    %{version: version} = published_version_fixture(scope, manual_trigger_snapshot_attrs())

    Repo.delete_all(
      from(registration in TriggerRegistration,
        where: registration.definition_version_id == ^version.id
      )
    )

    assert :ok = perform_job(RegistrationSyncWorker, %{})

    assert Repo.aggregate(
             from(registration in TriggerRegistration,
               where: registration.definition_version_id == ^version.id
             ),
             :count,
             :id
           ) == 1
  end

  test "deactivates registrations for unpublished versions" do
    scope = project_scope_fixture()
    %{version: version} = published_version_fixture(scope, manual_trigger_snapshot_attrs())

    update_result =
      version
      |> WorkflowDefinitionVersion.changeset(%{status: :archived})
      |> Repo.update()

    assert :ok ==
             (case update_result do
                {:ok, _version} -> :ok
                {:error, changeset} -> raise inspect(changeset.errors)
              end)

    assert :ok = perform_job(RegistrationSyncWorker, %{})

    statuses =
      TriggerRegistration
      |> where([registration], registration.definition_version_id == ^version.id)
      |> Repo.all()
      |> Enum.map(& &1.status)
      |> Enum.uniq()

    assert statuses == ["inactive"]
  end

  test "keeps only the latest published version registration active per workflow" do
    scope = project_scope_fixture()
    trigger_step_id = Ecto.UUID.generate()

    {:ok, %{definition: definition, draft: draft}} =
      Workflows.create_definition(scope, %{
        name: "Registration worker #{System.unique_integer([:positive])}",
        description: "Latest published version test"
      })

    assert {:ok, saved_v1} =
             Workflows.save_draft(
               scope,
               draft,
               manual_trigger_snapshot_attrs(trigger_step_id, "Manual v1")
             )

    assert {:ok, version_one} = Workflows.publish_draft(scope, saved_v1)

    assert {:ok, draft_two} = Workflows.edit_definition(scope, definition)

    assert {:ok, saved_v2} =
             Workflows.save_draft(
               scope,
               draft_two,
               manual_trigger_snapshot_attrs(trigger_step_id, "Manual v2")
             )

    assert {:ok, version_two} = Workflows.publish_draft(scope, saved_v2)

    version_one_registration =
      Repo.one!(
        from(registration in TriggerRegistration,
          where: registration.definition_version_id == ^version_one.id
        )
      )

    version_two_registration =
      Repo.one!(
        from(registration in TriggerRegistration,
          where: registration.definition_version_id == ^version_two.id
        )
      )

    {:ok, _registration} =
      version_one_registration
      |> TriggerRegistration.changeset(%{status: "active"})
      |> Repo.update()

    {:ok, _registration} =
      version_two_registration
      |> TriggerRegistration.changeset(%{status: "inactive"})
      |> Repo.update()

    assert :ok = perform_job(RegistrationSyncWorker, %{})

    assert Repo.get!(TriggerRegistration, version_one_registration.id).status == "inactive"
    assert Repo.get!(TriggerRegistration, version_two_registration.id).status == "active"
  end

  test "resets errored registrations past cooldown" do
    scope = project_scope_fixture()
    %{version: version} = published_version_fixture(scope, manual_trigger_snapshot_attrs())

    registration =
      Repo.one!(
        from(registration in TriggerRegistration,
          where: registration.definition_version_id == ^version.id
        )
      )

    cutoff = DateTime.add(DateTime.utc_now(), -10, :minute)

    assert {:ok, _registration} =
             registration
             |> TriggerRegistration.changeset(%{
               status: "errored",
               error_message: "boom",
               consecutive_errors: 3,
               last_error_at: cutoff
             })
             |> Repo.update()

    assert :ok = perform_job(RegistrationSyncWorker, %{})

    recovered = Repo.get!(TriggerRegistration, registration.id)

    assert recovered.status == "active"
    assert recovered.consecutive_errors == 0
    assert is_nil(recovered.last_error_at)
    assert is_nil(recovered.error_message)
  end

  test "recovers broken schedule chains by enqueuing a TriggerFireWorker" do
    scope = project_scope_fixture()
    %{version: version} = published_version_fixture(scope, schedule_trigger_snapshot_attrs())

    registration =
      Repo.one!(
        from(registration in TriggerRegistration,
          where:
            registration.definition_version_id == ^version.id and
              registration.kind == "schedule"
        )
      )

    # Set next_fire_at to the past to simulate an overdue registration
    overdue_at = DateTime.add(DateTime.utc_now(), -5, :minute)

    assert {:ok, _registration} =
             registration
             |> TriggerRegistration.changeset(%{next_fire_at: overdue_at})
             |> Repo.update()

    # Cancel any existing enqueued jobs for this registration to simulate a broken chain
    Repo.delete_all(
      from(job in Oban.Job,
        where:
          job.worker == "Fizz.Triggers.Workers.TriggerFireWorker" and
            fragment("?->>'trigger_registration_id' = ?", job.args, ^registration.id)
      )
    )

    assert :ok = perform_job(RegistrationSyncWorker, %{})

    # A recovery job should be enqueued
    recovery_jobs =
      all_enqueued(worker: TriggerFireWorker)
      |> Enum.filter(fn job ->
        job.args["trigger_registration_id"] == registration.id
      end)

    assert length(recovery_jobs) >= 1
  end

  defp schedule_trigger_snapshot_attrs do
    snapshot_attrs(%{
      steps: [
        step(%{
          id: Ecto.UUID.generate(),
          type_id: "schedule_trigger",
          name: "Schedule",
          config: %{"interval_seconds" => 60}
        })
      ]
    })
  end

  defp manual_trigger_snapshot_attrs(step_id \\ Ecto.UUID.generate(), name \\ "Manual") do
    snapshot_attrs(%{
      steps: [step(%{id: step_id, type_id: "manual_input", name: name})]
    })
  end
end
