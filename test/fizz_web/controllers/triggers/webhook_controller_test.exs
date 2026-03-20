defmodule FizzWeb.Triggers.WebhookControllerTest do
  use FizzWeb.ConnCase, async: false
  use Oban.Testing, repo: Fizz.Repo

  import Ecto.Query
  import Fizz.WorkflowsFixtures

  alias Fizz.Repo
  alias Fizz.Steps.Registry, as: StepRegistry
  alias Fizz.TestSupport.Executors.FailingWebhookTrigger
  alias Fizz.Triggers.Registry
  alias Fizz.Triggers.TriggerRegistration
  alias Fizz.Triggers.Workers.TriggerFireWorker

  setup do
    register_test_step_type(FailingWebhookTrigger)

    scope = project_scope_fixture()
    %{version: version} = published_version_fixture(scope, github_trigger_snapshot_attrs())
    registration = webhook_registration(version.id)

    start_supervised!({Registry, notifications?: false, refresh_interval_ms: :timer.hours(1)})
    :ok = Registry.refresh()

    %{scope: scope, registration: registration}
  end

  test "valid HMAC returns 202 Accepted and enqueues TriggerFireWorker", %{
    conn: conn,
    registration: registration
  } do
    registration_id = registration.id
    body = github_payload() |> Jason.encode!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "push")
      |> put_req_header("x-github-delivery", "delivery-123")
      |> put_req_header(
        "x-hub-signature-256",
        github_signature(body, registration.webhook_secret)
      )
      |> post(~p"/triggers/wh/#{registration.webhook_path}", body)

    assert response(conn, 202) == ""

    assert [
             %{
               args: %{
                 "trigger_registration_id" => ^registration_id,
                 "event_id" => "delivery-123",
                 "normalized_data" => %{"event_type" => "push"}
               }
             }
           ] = all_enqueued(worker: TriggerFireWorker)
  end

  test "invalid HMAC returns 401 Unauthorized", %{conn: conn, registration: registration} do
    body = github_payload() |> Jason.encode!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "push")
      |> put_req_header("x-hub-signature-256", github_signature(body, "wrong-secret"))
      |> post(~p"/triggers/wh/#{registration.webhook_path}", body)

    assert response(conn, 401) == ""
    assert [] == all_enqueued(worker: TriggerFireWorker)
  end

  test "unknown webhook_path returns 404 Not Found", %{conn: conn} do
    body = github_payload() |> Jason.encode!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/triggers/wh/unknown-path", body)

    assert response(conn, 404) == ""
  end

  test "match? returning false returns 200 OK without enqueueing a job", %{
    conn: conn,
    registration: registration
  } do
    body = github_payload() |> Jason.encode!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "issues")
      |> put_req_header(
        "x-hub-signature-256",
        github_signature(body, registration.webhook_secret)
      )
      |> post(~p"/triggers/wh/#{registration.webhook_path}", body)

    assert response(conn, 200) == ""
    assert [] == all_enqueued(worker: TriggerFireWorker)
  end

  test "normalize_event errors return 422 Unprocessable Entity", %{conn: conn, scope: scope} do
    %{version: version} = published_version_fixture(scope, failing_trigger_snapshot_attrs())
    registration = webhook_registration(version.id)
    :ok = Registry.refresh()

    body = github_payload() |> Jason.encode!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header(
        "x-hub-signature-256",
        github_signature(body, registration.webhook_secret)
      )
      |> post(~p"/triggers/wh/#{registration.webhook_path}", body)

    assert response(conn, 422) == ""
    assert [] == all_enqueued(worker: TriggerFireWorker)
  end

  defp github_trigger_snapshot_attrs do
    snapshot_attrs(%{
      steps: [
        step(%{
          id: Ecto.UUID.generate(),
          type_id: "github_trigger",
          name: "GitHub Trigger",
          config: %{
            "events" => ["push"],
            "repository" => "acme/site"
          }
        })
      ]
    })
  end

  defp failing_trigger_snapshot_attrs do
    snapshot_attrs(%{
      steps: [
        step(%{
          id: Ecto.UUID.generate(),
          type_id: "failing_webhook_trigger",
          name: "Failing Trigger"
        })
      ]
    })
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

  defp register_test_step_type(module) do
    definition = module.__step_definition__()
    :ok = StepRegistry.register(definition)

    on_exit(fn ->
      :ok = StepRegistry.unregister(definition.id)
    end)
  end
end
