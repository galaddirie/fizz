defmodule Fizz.Accounts.IntegrationsTest do
  use Fizz.DataCase, async: false

  alias Fizz.Accounts
  alias Fizz.Accounts.ByoCredential
  alias Fizz.Accounts.Integrations

  import Fizz.AccountsFixtures

  defmodule ReqMock do
    def request(opts) do
      if pid = Application.get_env(:fizz, :workos_req_mock_test_pid) do
        send(pid, {:workos_http_request, opts})
      end

      agent = Application.fetch_env!(:fizz, :workos_req_mock_agent)

      Agent.get_and_update(agent, fn
        [response | rest] -> {response, rest}
        [] -> {{:error, :no_mock_response}, []}
      end)
    end
  end

  setup do
    agent = start_supervised!({Agent, fn -> [] end})

    previous_http_client = Application.get_env(:fizz, :workos_http_client_module)
    previous_workos_client = Application.get_env(:workos, WorkOS.Client)
    previous_agent = Application.get_env(:fizz, :workos_req_mock_agent)
    previous_pid = Application.get_env(:fizz, :workos_req_mock_test_pid)

    Application.put_env(:fizz, :workos_http_client_module, ReqMock)
    Application.put_env(:fizz, :workos_req_mock_agent, agent)
    Application.put_env(:fizz, :workos_req_mock_test_pid, self())

    Application.put_env(:workos, WorkOS.Client,
      api_key: "sk_test_123",
      client_id: "client_test_123",
      client: Fizz.WorkOS.ReqClient
    )

    on_exit(fn ->
      restore_env(:fizz, :workos_http_client_module, previous_http_client)
      restore_env(:workos, WorkOS.Client, previous_workos_client)
      restore_env(:fizz, :workos_req_mock_agent, previous_agent)
      restore_env(:fizz, :workos_req_mock_test_pid, previous_pid)
    end)

    %{agent: agent}
  end

  test "create_byo_credential/2 stores metadata and calls Vault", %{agent: agent} do
    queue_http_responses(agent, [
      {:ok, %Req.Response{status: 201, body: %{"id" => "vault_obj_123"}}}
    ])

    scope = user_scope_fixture()

    assert {:ok, credential} =
             Accounts.create_byo_credential(scope, %{
               "provider" => "github",
               "label" => "Main automation key",
               "secret" => "12345678"
             })

    assert %ByoCredential{} = credential
    assert credential.provider == "github"
    assert credential.label == "Main automation key"
    assert credential.vault_object_id == "vault_obj_123"
    assert credential.status == :active
    assert credential.user_id == scope.user.id

    assert_receive {:workos_http_request, request}
    assert request[:method] == :post
    assert request[:url] == "/vault/objects"
    assert request[:json][:name] =~ "fizz-github-#{scope.user.id}"
    assert request[:json][:context]["provider"] == "github"
    assert request[:json][:context]["user_id"] == Integer.to_string(scope.user.id)
  end

  test "revoke_byo_credential/2 marks credential revoked and deletes vault object", %{
    agent: agent
  } do
    queue_http_responses(agent, [
      {:ok, %Req.Response{status: 204, body: %{}}}
    ])

    user = user_fixture()
    scope = user_scope_fixture(user)

    credential =
      Repo.insert!(%ByoCredential{
        user_id: user.id,
        provider: "github",
        label: "Legacy key",
        vault_object_id: "vault_obj_to_delete",
        status: :active,
        metadata: %{}
      })

    assert {:ok, revoked_credential} = Accounts.revoke_byo_credential(scope, credential.id)
    assert revoked_credential.status == :revoked
    assert revoked_credential.revoked_at

    assert_receive {:workos_http_request, request}
    assert request[:method] == :delete
    assert request[:url] == "/vault/objects/vault_obj_to_delete"

    persisted_credential = Repo.get!(ByoCredential, credential.id)
    assert persisted_credential.status == :revoked
  end

  test "list_connected_app_statuses/2 maps provider state from Pipes responses", %{agent: agent} do
    queue_http_responses(agent, [
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "active" => true,
           "access_token" => %{
             "token" => "gh_token",
             "scopes" => ["repo"],
             "missing_scopes" => []
           }
         }
       }},
      {:ok, %Req.Response{status: 200, body: %{"active" => false, "error" => "not_connected"}}},
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"active" => false, "error" => "needs_reauthorization"}
       }},
      {:ok, %Req.Response{status: 500, body: %{"message" => "provider unavailable"}}}
    ])

    user = user_fixture(%{workos_user_id: "user_workos_for_status"})
    scope = user_scope_fixture(user)

    assert {:ok, statuses} = Integrations.list_connected_app_statuses(scope, max_concurrency: 1)
    assert Enum.map(statuses, & &1.slug) == ["github", "google_drive", "slack", "microsoft_teams"]

    github_status = Enum.find(statuses, fn status -> status.slug == "github" end)
    google_status = Enum.find(statuses, fn status -> status.slug == "google_drive" end)
    slack_status = Enum.find(statuses, fn status -> status.slug == "slack" end)
    teams_status = Enum.find(statuses, fn status -> status.slug == "microsoft_teams" end)

    assert github_status.status == :connected
    assert github_status.connected?
    assert github_status.granted_scopes == ["repo"]

    assert google_status.status == :not_connected
    refute google_status.connected?

    assert slack_status.status == :needs_reauthorization
    refute slack_status.connected?

    assert teams_status.status == :unavailable
    refute teams_status.connected?
  end

  defp queue_http_responses(agent, responses) when is_list(responses) do
    Agent.update(agent, fn _ -> responses end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
