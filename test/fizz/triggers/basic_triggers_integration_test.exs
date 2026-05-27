defmodule Fizz.Triggers.BasicTriggersIntegrationTest do
  use FizzWeb.ConnCase, async: false
  use Oban.Testing, repo: Fizz.Repo

  import Ecto.Query
  import Fizz.WorkflowsFixtures

  alias Fizz.Accounts.OauthConnection
  alias Fizz.Repo
  alias Fizz.Fields.Credential
  alias Fizz.Triggers.Registry
  alias Fizz.Triggers.TriggerRegistration
  alias Fizz.Triggers.Workers.TriggerFireWorker
  alias Fizz.Workflows
  alias Fizz.Workflows.Runner.Worker
  alias Fizz.Workflows.WorkflowRun

  test "publish workflow with a schedule trigger enqueues initial Oban job and fires it", %{
    conn: _conn
  } do
    scope = project_scope_fixture()
    %{version: version} = published_version_fixture(scope, schedule_workflow_snapshot_attrs())
    registration = schedule_registration(version.id)

    assert registration.status == "active"
    assert registration.next_fire_at != nil

    # An initial TriggerFireWorker should have been enqueued at publish time
    jobs = all_enqueued(worker: TriggerFireWorker)

    assert Enum.any?(jobs, fn job ->
             job.args["trigger_registration_id"] == registration.id
           end)

    # Fire the job directly
    job =
      Enum.find(jobs, fn job ->
        job.args["trigger_registration_id"] == registration.id
      end)

    assert :ok = perform_job(TriggerFireWorker, job.args)

    run =
      eventually(fn ->
        WorkflowRun
        |> where([workflow_run], workflow_run.workflow_definition_version_id == ^version.id)
        |> order_by([workflow_run], desc: workflow_run.inserted_at)
        |> limit(1)
        |> Repo.one()
        |> case do
          %WorkflowRun{} = workflow_run -> {:ok, workflow_run}
          nil -> :retry
        end
      end)

    assert run.triggered_by["trigger_kind"] == "schedule"

    completed_run =
      eventually(fn ->
        case Workflows.get_run(scope, run.id) do
          {:ok, %WorkflowRun{status: :completed} = workflow_run} -> {:ok, workflow_run}
          _ -> :retry
        end
      end)

    assert completed_run.status == :completed
    assert_worker_shutdown(run.id)
  end

  test "publish workflow with a webhook trigger and fire it through the webhook controller", %{
    conn: conn
  } do
    scope = project_scope_fixture()
    version = publish_github_workflow!(scope, github_workflow_snapshot_attrs())
    registration = webhook_registration(version.id)

    start_supervised!({Registry, notifications?: false, refresh_interval_ms: :timer.hours(1)})
    :ok = Registry.refresh()

    body = github_payload() |> Jason.encode!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "push")
      |> put_req_header("x-github-delivery", "delivery-webhook")
      |> put_req_header(
        "x-hub-signature-256",
        github_signature(body, registration.webhook_secret)
      )
      |> post(~p"/triggers/wh/#{registration.webhook_path}", body)

    assert response(conn, 202) == ""

    [job] = all_enqueued(worker: TriggerFireWorker)
    assert :ok = perform_job(TriggerFireWorker, job.args)

    run =
      eventually(fn ->
        WorkflowRun
        |> where([workflow_run], workflow_run.workflow_definition_version_id == ^version.id)
        |> order_by([workflow_run], desc: workflow_run.inserted_at)
        |> limit(1)
        |> Repo.one()
        |> case do
          %WorkflowRun{} = workflow_run -> {:ok, workflow_run}
          nil -> :retry
        end
      end)

    assert run.triggered_by["trigger_kind"] == "webhook"
    assert run.triggered_by["event_id"] == "delivery-webhook"

    completed_run =
      eventually(fn ->
        case Workflows.get_run(scope, run.id) do
          {:ok, %WorkflowRun{status: :completed} = workflow_run} -> {:ok, workflow_run}
          _ -> :retry
        end
      end)

    assert completed_run.status == :completed
    assert_worker_shutdown(run.id)
  end

  test "re-publish preserves the existing webhook_path", %{conn: _conn} do
    scope = project_scope_fixture()
    trigger_step_id = Ecto.UUID.generate()
    %{definition: definition, draft: draft} = create_definition_fixture(scope)

    assert {:ok, saved_v1} =
             Workflows.save_draft(scope, draft, github_workflow_snapshot_attrs(trigger_step_id))

    bind_github_trigger!(saved_v1, scope, definition.id, trigger_step_id)

    assert {:ok, version_one} = Workflows.publish_draft(scope, saved_v1)

    first_registration = webhook_registration(version_one.id)

    assert {:ok, draft_two} = Workflows.edit_definition(scope, definition)

    assert {:ok, saved_v2} =
             Workflows.save_draft(
               scope,
               draft_two,
               github_workflow_snapshot_attrs(trigger_step_id, "acme/other-repo")
             )

    assert {:ok, version_two} = Workflows.publish_draft(scope, saved_v2)

    second_registration = webhook_registration(version_two.id)

    assert second_registration.webhook_path == first_registration.webhook_path
    assert second_registration.webhook_secret == first_registration.webhook_secret
  end

  defp schedule_workflow_snapshot_attrs do
    trigger =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "schedule_trigger",
        name: "Schedule Trigger",
        config: %{"interval_seconds" => 60}
      })

    debug = step(%{id: Ecto.UUID.generate(), type_id: "debug", name: "Debug"})

    snapshot_attrs(%{
      steps: [trigger, debug],
      connections: [connection(%{source_step_id: trigger.id, target_step_id: debug.id})]
    })
  end

  defp github_workflow_snapshot_attrs(step_id \\ Ecto.UUID.generate(), repository \\ "acme/site") do
    trigger =
      step(%{
        id: step_id,
        type_id: "github_trigger",
        name: "GitHub Trigger",
        config:
          "github_trigger"
          |> Fizz.Steps.Registry.get_default_config()
          |> Map.merge(%{"events" => ["push"], "repository" => repository})
      })

    debug = step(%{id: Ecto.UUID.generate(), type_id: "debug", name: "Debug"})

    snapshot_attrs(%{
      steps: [trigger, debug],
      connections: [connection(%{source_step_id: trigger.id, target_step_id: debug.id})]
    })
  end

  defp schedule_registration(version_id) do
    Repo.one!(
      from(registration in TriggerRegistration,
        where:
          registration.definition_version_id == ^version_id and registration.kind == "schedule"
      )
    )
  end

  defp webhook_registration(version_id) do
    Repo.one!(
      from(registration in TriggerRegistration,
        where:
          registration.definition_version_id == ^version_id and registration.kind == "webhook"
      )
    )
  end

  defp github_payload do
    %{
      "action" => "opened",
      "ref" => "refs/heads/main",
      "repository" => %{"full_name" => "acme/site"},
      "sender" => %{"login" => "monalisa"}
    }
  end

  defp github_signature(body, secret) do
    digest =
      :crypto.mac(:hmac, :sha256, secret, body)
      |> Base.encode16(case: :lower)

    "sha256=#{digest}"
  end

  defp create_definition_fixture(scope) do
    {:ok, %{definition: definition, draft: draft}} =
      Workflows.create_definition(scope, %{
        name: "Trigger Integration #{System.unique_integer([:positive])}",
        description: "Trigger integration test"
      })

    %{definition: definition, draft: draft}
  end

  defp publish_github_workflow!(scope, snapshot_attrs) do
    %{definition: definition, draft: draft} = create_definition_fixture(scope)
    [trigger | _steps] = snapshot_attrs.steps

    {:ok, saved_draft} = Workflows.save_draft(scope, draft, snapshot_attrs)
    bind_github_trigger!(saved_draft, scope, definition.id, trigger.id)

    assert {:ok, version} = Workflows.publish_draft(scope, saved_draft)
    version
  end

  defp bind_github_trigger!(version, scope, workflow_definition_id, trigger_step_id) do
    connection = insert_oauth_connection!(scope, "github_oauth")

    assert {:ok, _binding} =
             Credential.upsert_binding(version, scope, %{
               user_id: scope.user.id,
               workflow_definition_id: workflow_definition_id,
               step_id: trigger_step_id,
               requirement_key: "auth",
               binding_data: %{"credential_id" => connection.id},
               workos_organization_id: scope.organization_id
             })
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

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        receive do
        after
          20 -> eventually(fun, attempts - 1)
        end
    end
  end

  defp eventually(_fun, 0), do: flunk("condition was not met in time")

  defp assert_worker_shutdown(run_id) do
    case Worker.lookup(run_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end
  end
end
