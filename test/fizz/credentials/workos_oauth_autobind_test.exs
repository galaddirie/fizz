defmodule Fizz.Credentials.WorkOSOAuthAutobindTest do
  use Fizz.DataCase, async: false

  alias Fizz.Accounts.OauthConnection
  alias Fizz.Repo
  alias Fizz.Credentials
  alias Fizz.Workflows
  alias Fizz.Workflows.Readiness
  alias Fizz.WorkflowsFixtures
  alias Fizz.WorkOSHTTPMock

  setup do
    previous_http_client = Application.get_env(:fizz, :workos_http_client_module)
    previous_workos_http_backoff_ms = Application.get_env(:fizz, :workos_http_backoff_ms)
    previous_workos_client = Application.get_env(:workos, WorkOS.Client)
    store_pid = start_supervised!({Agent, fn -> [] end})

    :ok = WorkOSHTTPMock.configure(self(), store_pid)
    Application.put_env(:fizz, :workos_http_client_module, WorkOSHTTPMock)
    Application.put_env(:fizz, :workos_http_backoff_ms, 0)

    Application.put_env(:workos, WorkOS.Client,
      api_key: "sk_test_123",
      client_id: "client_test_123",
      client: Fizz.Accounts.WorkOS.ReqClient
    )

    on_exit(fn ->
      restore_env(:fizz, :workos_http_client_module, previous_http_client)
      restore_env(:fizz, :workos_http_backoff_ms, previous_workos_http_backoff_ms)
      restore_env(:workos, WorkOS.Client, previous_workos_client)
      WorkOSHTTPMock.reset()
    end)

    :ok
  end

  test "readiness auto-binds the single active WorkOS Pipes OAuth account" do
    scope = WorkflowsFixtures.project_scope_fixture()
    version = draft_with_google_oauth_credential(scope)

    other_user = Fizz.AccountsFixtures.user_fixture()

    %OauthConnection{}
    |> OauthConnection.changeset(%{
      workos_organization_id: scope.organization_id,
      user_id: other_user.id,
      provider: "google_oauth",
      status: :active
    })
    |> Repo.insert!()

    put_workos_responses([
      membership_response(scope.user.workos_user_id, scope.organization_id),
      active_google_token_response()
    ])

    assert :ready = Readiness.check(version, scope.user.id, scope)

    connection =
      Repo.get_by!(OauthConnection,
        workos_organization_id: scope.organization_id,
        user_id: scope.user.id,
        provider: "google_oauth"
      )

    assert connection.status == :active
    assert connection.scopes == ["https://www.googleapis.com/auth/spreadsheets"]

    assert [binding] =
             Credentials.list_for_user(
               scope.organization_id,
               version.workflow_definition_id,
               scope.user.id
             )

    assert binding.step_id == hd(version.steps).id
    assert binding.requirement_key == "auth"
    assert binding.binding_data == %{"credential_id" => connection.id}

    assert_receive {:workos_http_request, membership_request}
    assert membership_request[:url] == "/user_management/organization_memberships"

    assert_receive {:workos_http_request, token_request}
    assert token_request[:url] == "/data-integrations/google/token"
  end

  defp draft_with_google_oauth_credential(scope) do
    {:ok, %{draft: draft}} =
      Workflows.create_definition(scope, %{
        name: "Google OAuth credential #{System.unique_integer([:positive])}",
        description: "Auto-bind test"
      })

    step =
      WorkflowsFixtures.step(%{
        type_id: "debug",
        name: "Needs Google",
        config: %{
          "credential_ref" => %{
            "$credential" => true,
            "requirement_key" => "auth",
            "provider" => "google_oauth",
            "auth_type" => "oauth"
          }
        }
      })

    attrs = WorkflowsFixtures.snapshot_attrs(%{steps: [step]})
    {:ok, version} = Workflows.save_draft(scope, draft, attrs)

    version
  end

  defp active_google_token_response do
    {:ok,
     %Req.Response{
       status: 200,
       body: %{
         "active" => true,
         "access_token" => %{
           "access_token" => "ya29.test",
           "expires_at" => "2026-12-31T23:59:59.000Z",
           "scopes" => ["https://www.googleapis.com/auth/spreadsheets"],
           "missing_scopes" => []
         }
       }
     }}
  end

  defp membership_response(workos_user_id, organization_id) do
    {:ok,
     %Req.Response{
       status: 200,
       body: %{
         "data" => [
           %{
             "id" => "om_#{organization_id}",
             "status" => "active",
             "user_id" => workos_user_id,
             "organization_id" => organization_id,
             "role" => %{"slug" => "owner"}
           }
         ]
       }
     }}
  end

  defp put_workos_responses(responses), do: WorkOSHTTPMock.put_responses(responses)

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
