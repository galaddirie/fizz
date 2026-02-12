defmodule Fizz.Accounts.WorkOSTest do
  use ExUnit.Case, async: false

  alias Fizz.Accounts.{Tenant, User}
  alias Fizz.Accounts.WorkOS, as: AccountsWorkOS

  defmodule ReqMock do
    def request(opts) do
      send(self(), {:workos_http_request, opts})

      case Process.get(:workos_http_responses, []) do
        [response | rest] ->
          Process.put(:workos_http_responses, rest)
          response

        [] ->
          raise "No mocked WorkOS HTTP responses were configured"
      end
    end
  end

  setup do
    previous_http_client = Application.get_env(:fizz, :workos_http_client_module)
    previous_sync_enabled = Application.get_env(:fizz, :workos_sync_enabled)
    previous_role_slug_map = Application.get_env(:fizz, :workos_role_slug_map)
    previous_workos_client = Application.get_env(:workos, WorkOS.Client)

    Application.put_env(:fizz, :workos_http_client_module, ReqMock)
    Application.put_env(:fizz, :workos_sync_enabled, true)

    Application.put_env(:fizz, :workos_role_slug_map, %{
      owner: "owner",
      admin: "admin",
      member: "member"
    })

    Application.put_env(:workos, WorkOS.Client,
      api_key: "sk_test_123",
      client_id: "client_test_123",
      client: Fizz.WorkOS.ReqClient
    )

    on_exit(fn ->
      restore_env(:fizz, :workos_http_client_module, previous_http_client)
      restore_env(:fizz, :workos_sync_enabled, previous_sync_enabled)
      restore_env(:fizz, :workos_role_slug_map, previous_role_slug_map)
      restore_env(:workos, WorkOS.Client, previous_workos_client)
    end)

    :ok
  end

  test "ensure_organization_membership/3 updates existing membership role when mismatched" do
    Process.put(:workos_http_responses, [
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "data" => [
             %{
               "id" => "om_123",
               "status" => "active",
               "role" => %{"slug" => "member"}
             }
           ]
         }
       }},
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"id" => "om_123", "status" => "active", "role" => %{"slug" => "admin"}}
       }}
    ])

    tenant = %Tenant{workos_organization_id: "org_123"}
    user = %User{id: 7, email: "owner@example.com", workos_user_id: "user_123"}

    assert {:ok, %{membership_id: "om_123", user_id: "user_123"}} =
             AccountsWorkOS.ensure_organization_membership(tenant, user, :admin)

    assert_receive {:workos_http_request, first_request}
    assert first_request[:method] == :get
    assert first_request[:url] == "/user_management/organization_memberships"

    params = first_request[:params]
    assert Enum.any?(params, fn {key, value} -> key == :user_id and value == "user_123" end)

    assert Enum.any?(params, fn {key, value} -> key == :organization_id and value == "org_123" end)

    assert_receive {:workos_http_request, second_request}
    assert second_request[:method] == :put
    assert second_request[:url] == "/user_management/organization_memberships/om_123"
    assert second_request[:json] == %{role_slug: "admin"}
  end

  test "ensure_organization_membership/3 creates membership with mapped role slug" do
    Application.put_env(:fizz, :workos_role_slug_map, %{
      owner: "agency_owner",
      admin: "admin",
      member: "member"
    })

    Process.put(:workos_http_responses, [
      {:ok, %Req.Response{status: 200, body: %{"data" => []}}},
      {:ok,
       %Req.Response{
         status: 201,
         body: %{
           "id" => "om_created",
           "status" => "active",
           "role" => %{"slug" => "agency_owner"}
         }
       }}
    ])

    tenant = %Tenant{workos_organization_id: "org_987"}
    user = %User{id: 17, email: "new-owner@example.com", workos_user_id: "user_987"}

    assert {:ok, %{membership_id: "om_created", user_id: "user_987"}} =
             AccountsWorkOS.ensure_organization_membership(tenant, user, :owner)

    assert_receive {:workos_http_request, _first_request}

    assert_receive {:workos_http_request, second_request}
    assert second_request[:method] == :post
    assert second_request[:url] == "/user_management/organization_memberships"

    assert second_request[:json] == %{
             user_id: "user_987",
             organization_id: "org_987",
             role_slug: "agency_owner"
           }
  end

  test "ensure_organization_membership/3 is a no-op when sync is disabled" do
    Application.put_env(:fizz, :workos_sync_enabled, false)

    tenant = %Tenant{workos_organization_id: "org_123"}
    user = %User{id: 99, email: "member@example.com", workos_user_id: "user_123"}

    assert {:ok, %{membership_id: nil, user_id: "user_123"}} =
             AccountsWorkOS.ensure_organization_membership(tenant, user, :member)

    refute_receive {:workos_http_request, _request}
  end

  test "create_vault_object/1 posts to vault objects endpoint" do
    Process.put(:workos_http_responses, [
      {:ok, %Req.Response{status: 201, body: %{"id" => "vault_obj_123"}}}
    ])

    assert {:ok, %{"id" => "vault_obj_123"}} =
             AccountsWorkOS.create_vault_object(%{
               name: "slack-token",
               value: "xoxb-example",
               context: %{"organization_id" => "org_123"}
             })

    assert_receive {:workos_http_request, request}
    assert request[:method] == :post
    assert request[:url] == "/vault/objects"

    assert request[:json] == %{
             name: "slack-token",
             value: "xoxb-example",
             context: %{"organization_id" => "org_123"}
           }
  end

  test "delete_vault_object/1 sends delete request" do
    Process.put(:workos_http_responses, [
      {:ok, %Req.Response{status: 204, body: %{}}}
    ])

    assert :ok = AccountsWorkOS.delete_vault_object("vault_obj_123")

    assert_receive {:workos_http_request, request}
    assert request[:method] == :delete
    assert request[:url] == "/vault/objects/vault_obj_123"
  end

  test "generate_widget_token/1 posts to widgets token endpoint" do
    Process.put(:workos_http_responses, [
      {:ok, %Req.Response{status: 200, body: %{"token" => "widget_token_123"}}}
    ])

    assert {:ok, "widget_token_123"} =
             AccountsWorkOS.generate_widget_token(%{
               organization_id: "org_123",
               user_id: "user_123",
               scopes: []
             })

    assert_receive {:workos_http_request, request}
    assert request[:method] == :post
    assert request[:url] == "/widgets/token"

    assert request[:json] == %{
             organization_id: "org_123",
             user_id: "user_123",
             scopes: []
           }
  end

  test "get_pipes_access_token/3 posts to data integrations token endpoint" do
    Process.put(:workos_http_responses, [
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "active" => true,
           "access_token" => %{
             "access_token" => "gho_123",
             "expires_at" => "2025-12-31T23:59:59.000Z",
             "scopes" => ["repo"],
             "missing_scopes" => ["read:org"]
           }
         }
       }}
    ])

    assert {:ok, response} =
             AccountsWorkOS.get_pipes_access_token("github", "user_123", "org_123")

    assert response == %{
             active: true,
             access_token: "gho_123",
             expires_at: "2025-12-31T23:59:59.000Z",
             scopes: ["repo"],
             missing_scopes: ["read:org"],
             error: nil
           }

    assert_receive {:workos_http_request, request}
    assert request[:method] == :post
    assert request[:url] == "/data-integrations/github/token"

    assert request[:json] == %{
             user_id: "user_123",
             organization_id: "org_123"
           }
  end

  test "get_pipes_access_token/3 normalizes provider error response" do
    Process.put(:workos_http_responses, [
      {:ok, %Req.Response{status: 200, body: %{"active" => false, "error" => "not_installed"}}}
    ])

    assert {:ok, response} =
             AccountsWorkOS.get_pipes_access_token("google", "user_456", "org_456")

    assert response == %{
             active: false,
             access_token: nil,
             expires_at: nil,
             scopes: [],
             missing_scopes: [],
             error: :not_installed
           }

    assert_receive {:workos_http_request, request}
    assert request[:method] == :post
    assert request[:url] == "/data-integrations/google/token"
  end

  test "list_user_organization_memberships/1 returns active memberships" do
    Process.put(:workos_http_responses, [
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "data" => [
             %{"id" => "om_1", "organization_id" => "org_active", "status" => "active"},
             %{"id" => "om_2", "organization_id" => "org_inactive", "status" => "inactive"},
             %{"id" => "om_3", "organization_id" => "org_unknown"}
           ]
         }
       }}
    ])

    assert {:ok, memberships} = AccountsWorkOS.list_user_organization_memberships("user_123")

    assert Enum.map(memberships, fn membership ->
             membership["organization_id"]
           end) == ["org_active", "org_unknown"]

    assert_receive {:workos_http_request, request}
    assert request[:method] == :get
    assert request[:url] == "/user_management/organization_memberships"

    params = request[:params]
    assert Enum.any?(params, fn {key, value} -> key == :user_id and value == "user_123" end)
    assert Enum.any?(params, fn {key, value} -> key == :limit and value == 10 end)

    refute Enum.any?(params, fn {key, _value} -> key == :organization_id end)
  end

  test "user_has_organization_membership?/2 checks active membership in organization" do
    Process.put(:workos_http_responses, [
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "data" => [
             %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"}
           ]
         }
       }}
    ])

    assert {:ok, true} = AccountsWorkOS.user_has_organization_membership?("user_123", "org_123")

    assert_receive {:workos_http_request, request}
    assert request[:method] == :get
    assert request[:url] == "/user_management/organization_memberships"

    params = request[:params]
    assert Enum.any?(params, fn {key, value} -> key == :user_id and value == "user_123" end)

    assert Enum.any?(params, fn {key, value} ->
             key == :organization_id and value == "org_123"
           end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
