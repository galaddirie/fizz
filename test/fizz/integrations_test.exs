defmodule Fizz.IntegrationsTest do
  use Fizz.DataCase, async: false

  alias Fizz.Accounts.Scope
  alias Fizz.Accounts.Integrations, as: AccountIntegrations
  alias Fizz.Accounts.ApiCredential
  alias Fizz.Integrations
  alias Fizz.WorkOSHTTPMock

  import Fizz.AccountsFixtures

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

  test "create/rotate/resolve/delete credential lifecycle" do
    user = user_fixture()
    org_id = "org_123"

    owner_scope =
      organization_scope_fixture(user: user, organization_id: org_id, organization_role: :owner)

    _workspace = workspace_fixture(owner_scope, %{name: "Workspace A"})
    scope = Scope.for_user(user)

    put_workos_responses([
      membership_response(user.workos_user_id, org_id),
      {:ok,
       %Req.Response{
         status: 201,
         body: %{
           "id" => "vault_obj_123",
           "metadata" => %{"version_id" => "version_1"}
         }
       }},
      membership_response(user.workos_user_id, org_id),
      {:ok, %Req.Response{status: 200, body: %{"metadata" => %{"version_id" => "version_2"}}}},
      membership_response(user.workos_user_id, org_id),
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "id" => "vault_obj_123",
           "value" => "sk-new"
         }
       }},
      membership_response(user.workos_user_id, org_id),
      {:ok, %Req.Response{status: 204, body: %{}}}
    ])

    assert {:ok, credential} =
             AccountIntegrations.create_credential(scope, org_id, %{
               provider: "openai_api_key",
               provider_label: "OpenAI Production",
               secret: "sk-original"
             })

    assert credential.provider == "openai_api_key"
    assert credential.vault_object_id == "vault_obj_123"
    assert credential.vault_version == "version_1"

    assert {:ok, rotated} =
             AccountIntegrations.rotate_credential(scope, org_id, credential.id, %{
               secret: "sk-new"
             })

    assert rotated.vault_version == "version_2"

    assert {:ok, resolved} =
             AccountIntegrations.resolve_credential_for_use(scope, org_id, "openai_api_key",
               api_credential_id: credential.id
             )

    assert resolved.api_key == "sk-new"
    assert resolved.api_credential_id == credential.id

    assert {:ok, _deleted} = AccountIntegrations.delete_credential(scope, org_id, credential.id)
    refute Repo.get(ApiCredential, credential.id)
  end

  test "fetch_token_for_sprite/3 resolves api_key auth directly from credentials" do
    user = user_fixture()
    org_id = "org_234"

    owner_scope =
      organization_scope_fixture(user: user, organization_id: org_id, organization_role: :owner)

    workspace = workspace_fixture(owner_scope, %{name: "Workspace B"})
    scope = Scope.for_user(user)

    put_workos_responses([
      membership_response(user.workos_user_id, org_id),
      {:ok,
       %Req.Response{
         status: 201,
         body: %{
           "id" => "vault_obj_234",
           "metadata" => %{"version_id" => "version_1"}
         }
       }},
      membership_response(user.workos_user_id, org_id),
      {:ok, %Req.Response{status: 200, body: %{"id" => "vault_obj_234", "value" => "sk-api-key"}}}
    ])

    assert {:ok, credential} =
             AccountIntegrations.create_credential(scope, org_id, %{
               provider: "openai_api_key",
               provider_label: "OpenAI",
               secret: "sk-api-key"
             })

    assert {:ok, token_result} =
             Integrations.fetch_token_for_sprite(scope, workspace.id, "openai_api_key")

    assert token_result.access_token == "sk-api-key"
    assert credential.provider == "openai_api_key"
  end

  test "credential usage is organization-scoped across workspaces" do
    user = user_fixture()
    org_id = "org_345"

    owner_scope =
      organization_scope_fixture(user: user, organization_id: org_id, organization_role: :owner)

    _workspace_a = workspace_fixture(owner_scope, %{name: "Workspace C"})
    _workspace_b = workspace_fixture(owner_scope, %{name: "Workspace D"})
    scope = Scope.for_user(user)

    put_workos_responses([
      membership_response(user.workos_user_id, org_id),
      {:ok,
       %Req.Response{
         status: 201,
         body: %{
           "id" => "vault_obj_345",
           "metadata" => %{"version_id" => "version_1"}
         }
       }}
    ])

    assert {:ok, credential} =
             AccountIntegrations.create_credential(scope, org_id, %{
               provider: "anthropic_api_key",
               provider_label: "Anthropic",
               secret: "sk-anthropic"
             })

    put_workos_responses([
      membership_response(user.workos_user_id, org_id),
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "id" => "vault_obj_345",
           "value" => "sk-anthropic"
         }
       }}
    ])

    assert {:ok, resolved} =
             AccountIntegrations.resolve_credential_for_use(scope, org_id, "anthropic_api_key",
               api_credential_id: credential.id
             )

    assert resolved.api_key == "sk-anthropic"
  end

  test "credential usage is owner-scoped within workspace" do
    owner_user = user_fixture()
    member_user = user_fixture()
    org_id = "org_456"

    owner_scope =
      organization_scope_fixture(
        user: owner_user,
        organization_id: org_id,
        organization_role: :owner
      )

    workspace = workspace_fixture(owner_scope, %{name: "Workspace E"})

    {:ok, _member_membership} =
      Fizz.Accounts.add_workspace_member(owner_scope, workspace.id, member_user, %{role: :member})

    owner_runtime_scope = Scope.for_user(owner_user)
    member_runtime_scope = Scope.for_user(member_user)

    put_workos_responses([
      membership_response(owner_user.workos_user_id, org_id),
      {:ok,
       %Req.Response{
         status: 201,
         body: %{
           "id" => "vault_obj_456",
           "metadata" => %{"version_id" => "version_1"}
         }
       }},
      membership_response(member_user.workos_user_id, org_id)
    ])

    assert {:ok, credential} =
             AccountIntegrations.create_credential(owner_runtime_scope, org_id, %{
               provider: "openai_api_key",
               provider_label: "OpenAI Owner",
               secret: "sk-owner"
             })

    assert {:error, :credential_not_found} =
             AccountIntegrations.resolve_credential_for_use(
               member_runtime_scope,
               org_id,
               "openai_api_key",
               api_credential_id: credential.id
             )
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
