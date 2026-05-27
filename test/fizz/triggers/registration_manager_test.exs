defmodule Fizz.Triggers.RegistrationManagerTest do
  use Fizz.DataCase, async: false
  use Oban.Testing, repo: Fizz.Repo

  import Fizz.WorkflowsFixtures

  alias Fizz.Accounts.OauthConnection
  alias Fizz.Repo
  alias Fizz.Credentials
  alias Fizz.Triggers
  alias Fizz.Triggers.RegistrationManager
  alias Fizz.Triggers.{TriggerRegistration, TriggerSource}
  alias Fizz.Triggers.Workers.TriggerFireWorker
  alias Fizz.Workflows

  test "sync_on_publish creates registrations from trigger manifest" do
    scope = project_scope_fixture()
    %{version: version} = published_version_fixture(scope, multi_trigger_snapshot_attrs())

    Repo.delete_all(TriggerRegistration)

    assert :ok = RegistrationManager.sync_on_publish(version)

    assert {:ok, registrations} =
             Triggers.list_registrations(scope, definition_id: version.workflow_definition_id)

    assert Enum.sort(Enum.map(registrations, & &1.kind)) == ["manual", "schedule"]
    assert Enum.all?(registrations, &(&1.definition_version_id == version.id))
    assert Enum.any?(registrations, &(&1.kind == "schedule" and not is_nil(&1.next_fire_at)))
  end

  test "sync_on_publish requires bindings for trigger credentials" do
    scope = project_scope_fixture()

    trigger =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "github_trigger",
        name: "GitHub Trigger",
        config:
          "github_trigger"
          |> Fizz.Steps.Registry.get_default_config()
          |> Map.put("repository", "acme/site")
      })

    %{version: version} = published_version_fixture(scope, snapshot_attrs(%{steps: [trigger]}))

    assert {:error, [%{step_id: step_id, reason: {:credential_binding_required, "auth"}}]} =
             RegistrationManager.sync_on_publish(version)

    assert step_id == trigger.id
  end

  test "sync_on_publish deactivates previous version registrations" do
    scope = project_scope_fixture()
    %{definition: definition, draft: draft} = definition_fixture(scope)

    assert {:ok, saved_v1} = Workflows.save_draft(scope, draft, multi_trigger_snapshot_attrs())
    assert {:ok, version_one} = Workflows.publish_draft(scope, saved_v1)

    assert {:ok, draft_two} = Workflows.edit_definition(scope, definition)
    assert {:ok, saved_v2} = Workflows.save_draft(scope, draft_two, manual_only_snapshot_attrs())
    assert {:ok, version_two} = Workflows.publish_draft(scope, saved_v2)

    assert :ok = RegistrationManager.sync_on_publish(version_two)

    version_one_statuses =
      TriggerRegistration
      |> where([registration], registration.definition_version_id == ^version_one.id)
      |> Repo.all()
      |> Enum.map(& &1.status)
      |> Enum.uniq()

    version_two_statuses =
      TriggerRegistration
      |> where([registration], registration.definition_version_id == ^version_two.id)
      |> Repo.all()
      |> Enum.map(& &1.status)
      |> Enum.uniq()

    assert version_one_statuses == ["inactive"]
    assert version_two_statuses == ["active"]
  end

  test "sync_on_publish is idempotent for the same config" do
    scope = project_scope_fixture()
    %{version: version} = published_version_fixture(scope, multi_trigger_snapshot_attrs())

    count_before =
      TriggerRegistration
      |> where([registration], registration.definition_version_id == ^version.id)
      |> Repo.aggregate(:count, :id)

    assert :ok = RegistrationManager.sync_on_publish(version)

    count_after =
      TriggerRegistration
      |> where([registration], registration.definition_version_id == ^version.id)
      |> Repo.aggregate(:count, :id)

    assert count_after == count_before
  end

  test "sync_on_publish creates a shared polling source for Google Sheets triggers" do
    scope = project_scope_fixture()

    trigger =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "google_sheets_trigger",
        name: "Google Sheets Trigger",
        config: %{
          "credential_ref" => credential_declaration("google_oauth", "oauth"),
          "spreadsheet_id" => "spreadsheet_1",
          "sheet_name" => "Sheet1",
          "event_mode" => "row_added_or_updated",
          "range" => "A:ZZZ",
          "poll_interval_ms" => 60_000
        }
      })

    %{definition: definition, draft: draft} = definition_fixture(scope)
    {:ok, saved_draft} = Workflows.save_draft(scope, draft, snapshot_attrs(%{steps: [trigger]}))
    connection = insert_oauth_connection!(scope, "google_oauth")

    assert {:ok, _binding} =
             Credentials.upsert_binding(saved_draft, scope, %{
               user_id: scope.user.id,
               workflow_definition_id: definition.id,
               step_id: trigger.id,
               requirement_key: "auth",
               binding_data: %{"credential_id" => connection.id},
               workos_organization_id: scope.organization_id
             })

    assert {:ok, version} = Workflows.publish_draft(scope, saved_draft)

    assert :ok = RegistrationManager.sync_on_publish(version)

    registration =
      Repo.one!(
        from(registration in TriggerRegistration,
          where:
            registration.definition_version_id == ^version.id and
              registration.step_id == ^trigger.id
        )
      )

    source = Repo.get!(TriggerSource, registration.trigger_source_id)

    assert registration.kind == "polling"
    assert source.provider == "google_oauth"
    assert source.source_module == "Fizz.Integrations.Google.Sheets.Triggers.RowChange"
    assert source.params["spreadsheet_id"] == "spreadsheet_1"
    assert source.cursor == %{"initialized" => false}
  end

  test "sync_on_publish enqueues initial TriggerFireWorker for schedule triggers" do
    scope = project_scope_fixture()
    %{version: version} = published_version_fixture(scope, multi_trigger_snapshot_attrs())

    schedule_registration =
      TriggerRegistration
      |> where(
        [registration],
        registration.definition_version_id == ^version.id and registration.kind == "schedule"
      )
      |> Repo.one!()

    assert schedule_registration.next_fire_at != nil

    jobs =
      all_enqueued(worker: TriggerFireWorker)
      |> Enum.filter(fn job ->
        job.args["trigger_registration_id"] == schedule_registration.id
      end)

    assert length(jobs) == 1
    [job] = jobs
    assert job.args["event_id"] =~ "sched_#{schedule_registration.id}_"
  end

  test "sync_on_publish preserves existing webhook credentials across re-publish" do
    scope = project_scope_fixture()
    trigger_step_id = Ecto.UUID.generate()
    %{definition: definition, draft: draft} = definition_fixture(scope)

    assert {:ok, saved_v1} =
             Workflows.save_draft(scope, draft, webhook_snapshot_attrs(trigger_step_id))

    connection = insert_oauth_connection!(scope, "github_oauth")

    assert {:ok, _binding} =
             Credentials.upsert_binding(saved_v1, scope, %{
               user_id: scope.user.id,
               workflow_definition_id: definition.id,
               step_id: trigger_step_id,
               requirement_key: "auth",
               binding_data: %{"credential_id" => connection.id},
               workos_organization_id: scope.organization_id
             })

    assert {:ok, version_one} = Workflows.publish_draft(scope, saved_v1)

    first_registration =
      Repo.one!(
        from(registration in TriggerRegistration,
          where:
            registration.definition_version_id == ^version_one.id and
              registration.kind == "webhook"
        )
      )

    assert {:ok, draft_two} = Workflows.edit_definition(scope, definition)

    assert {:ok, saved_v2} =
             Workflows.save_draft(
               scope,
               draft_two,
               webhook_snapshot_attrs(trigger_step_id, "acme/other-repo")
             )

    assert {:ok, version_two} = Workflows.publish_draft(scope, saved_v2)

    second_registration =
      Repo.one!(
        from(registration in TriggerRegistration,
          where:
            registration.definition_version_id == ^version_two.id and
              registration.kind == "webhook"
        )
      )

    assert second_registration.webhook_path == first_registration.webhook_path
    assert second_registration.webhook_secret == first_registration.webhook_secret
  end

  defp definition_fixture(scope) do
    {:ok, %{definition: definition, draft: draft}} =
      Workflows.create_definition(scope, %{
        name: "Registration Manager #{System.unique_integer([:positive])}",
        description: "Manager test"
      })

    %{definition: definition, draft: draft}
  end

  defp multi_trigger_snapshot_attrs do
    manual = step(%{id: Ecto.UUID.generate(), type_id: "manual_input", name: "Manual"})

    schedule =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "schedule_trigger",
        name: "Schedule",
        config: %{"interval_seconds" => 60}
      })

    snapshot_attrs(%{steps: [manual, schedule]})
  end

  defp manual_only_snapshot_attrs do
    snapshot_attrs(%{
      steps: [step(%{id: Ecto.UUID.generate(), type_id: "manual_input", name: "Manual"})]
    })
  end

  defp webhook_snapshot_attrs(step_id, repository \\ "acme/site") do
    snapshot_attrs(%{
      steps: [
        step(%{
          id: step_id,
          type_id: "github_trigger",
          name: "GitHub Trigger",
          config:
            "github_trigger"
            |> Fizz.Steps.Registry.get_default_config()
            |> Map.merge(%{"events" => ["push"], "repository" => repository})
        })
      ]
    })
  end

  defp credential_declaration(provider, auth_type) do
    %{
      "$credential" => true,
      "requirement_key" => "auth",
      "provider" => provider,
      "auth_type" => auth_type
    }
  end

  defp insert_oauth_connection!(scope, provider) do
    %OauthConnection{}
    |> OauthConnection.changeset(%{
      workos_organization_id: scope.organization_id,
      user_id: scope.user.id,
      provider: provider,
      status: :active
    })
    |> Repo.insert!()
  end
end
