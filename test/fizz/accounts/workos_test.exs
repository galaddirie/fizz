defmodule Fizz.Accounts.WorkOSTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Fizz.Accounts.User
  alias Fizz.Accounts.WorkOS, as: AccountsWorkOS

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    previous_http_client = Application.get_env(:fizz, :workos_http_client_module)
    previous_http_plug = Application.get_env(:fizz, :workos_http_plug)
    previous_sync_enabled = Application.get_env(:fizz, :workos_sync_enabled)
    previous_role_slug_map = Application.get_env(:fizz, :workos_role_slug_map)
    previous_workos_client = Application.get_env(:workos, WorkOS.Client)

    Application.put_env(:fizz, :workos_http_client_module, Req)
    Application.put_env(:fizz, :workos_http_plug, {Req.Test, :workos_api})
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
      restore_env(:fizz, :workos_http_plug, previous_http_plug)
      restore_env(:fizz, :workos_sync_enabled, previous_sync_enabled)
      restore_env(:fizz, :workos_role_slug_map, previous_role_slug_map)
      restore_env(:workos, WorkOS.Client, previous_workos_client)
    end)

    :ok
  end

  test "ensure_organization_membership/3 updates existing membership role when mismatched" do
    Req.Test.expect(:workos_api, fn conn ->
      conn = fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/user_management/organization_memberships"
      assert conn.query_params["user_id"] == "user_123"
      assert conn.query_params["organization_id"] == "org_123"
      assert conn.query_params["limit"] == "10"

      json_response(conn, 200, %{
        "data" => [
          %{
            "id" => "om_123",
            "status" => "active",
            "role" => %{"slug" => "member"}
          }
        ]
      })
    end)

    Req.Test.expect(:workos_api, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/user_management/organization_memberships/om_123"
      assert decode_json(conn) == %{"role_slug" => "admin"}

      json_response(conn, 200, %{
        "id" => "om_123",
        "status" => "active",
        "role" => %{"slug" => "admin"}
      })
    end)

    user = %User{id: 7, email: "owner@example.com", workos_user_id: "user_123"}

    assert {:ok, %{membership_id: "om_123", user_id: "user_123"}} =
             AccountsWorkOS.ensure_organization_membership("org_123", user, :admin)
  end

  test "ensure_organization_membership/3 creates membership with mapped role slug" do
    Application.put_env(:fizz, :workos_role_slug_map, %{
      owner: "agency_owner",
      admin: "admin",
      member: "member"
    })

    Req.Test.expect(:workos_api, fn conn ->
      conn = fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/user_management/organization_memberships"
      assert conn.query_params["user_id"] == "user_987"
      assert conn.query_params["organization_id"] == "org_987"

      json_response(conn, 200, %{"data" => []})
    end)

    Req.Test.expect(:workos_api, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/user_management/organization_memberships"

      assert decode_json(conn) == %{
               "user_id" => "user_987",
               "organization_id" => "org_987",
               "role_slug" => "agency_owner"
             }

      json_response(conn, 201, %{
        "id" => "om_created",
        "status" => "active",
        "role" => %{"slug" => "agency_owner"}
      })
    end)

    user = %User{id: 17, email: "new-owner@example.com", workos_user_id: "user_987"}

    assert {:ok, %{membership_id: "om_created", user_id: "user_987"}} =
             AccountsWorkOS.ensure_organization_membership("org_987", user, :owner)
  end

  test "ensure_organization_membership/3 is a no-op when sync is disabled" do
    Application.put_env(:fizz, :workos_sync_enabled, false)

    user = %User{id: 99, email: "member@example.com", workos_user_id: "user_123"}

    assert {:ok, %{membership_id: nil, user_id: "user_123"}} =
             AccountsWorkOS.ensure_organization_membership("org_123", user, :member)
  end

  test "create_vault_object/1 posts to vault objects endpoint" do
    Req.Test.expect(:workos_api, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/vault/objects"

      assert decode_json(conn) == %{
               "name" => "slack-token",
               "value" => "xoxb-example",
               "context" => %{"organization_id" => "org_123"}
             }

      json_response(conn, 201, %{"id" => "vault_obj_123"})
    end)

    assert {:ok, %{"id" => "vault_obj_123"}} =
             AccountsWorkOS.create_vault_object(%{
               name: "slack-token",
               value: "xoxb-example",
               context: %{"organization_id" => "org_123"}
             })
  end

  test "delete_vault_object/1 sends delete request" do
    Req.Test.expect(:workos_api, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/vault/objects/vault_obj_123"

      send_resp(conn, 204, "")
    end)

    assert :ok = AccountsWorkOS.delete_vault_object("vault_obj_123")
  end

  test "generate_widget_token/1 posts to widgets token endpoint" do
    Req.Test.expect(:workos_api, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/widgets/token"

      assert decode_json(conn) == %{
               "organization_id" => "org_123",
               "user_id" => "user_123",
               "scopes" => []
             }

      json_response(conn, 200, %{"token" => "widget_token_123"})
    end)

    assert {:ok, "widget_token_123"} =
             AccountsWorkOS.generate_widget_token(%{
               organization_id: "org_123",
               user_id: "user_123",
               scopes: []
             })
  end

  test "get_pipes_access_token/3 posts to data integrations token endpoint" do
    Req.Test.expect(:workos_api, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/data-integrations/github/token"

      assert decode_json(conn) == %{
               "user_id" => "user_123",
               "organization_id" => "org_123"
             }

      json_response(conn, 200, %{
        "active" => true,
        "access_token" => %{
          "access_token" => "gho_123",
          "expires_at" => "2025-12-31T23:59:59.000Z",
          "scopes" => ["repo"],
          "missing_scopes" => ["read:org"]
        }
      })
    end)

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
  end

  test "get_pipes_access_token/3 normalizes provider error response" do
    Req.Test.expect(:workos_api, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/data-integrations/google/token"
      json_response(conn, 200, %{"active" => false, "error" => "not_installed"})
    end)

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
  end

  test "list_user_organization_memberships/1 returns active memberships" do
    Req.Test.expect(:workos_api, fn conn ->
      conn = fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/user_management/organization_memberships"
      assert conn.query_params["user_id"] == "user_123"
      assert conn.query_params["limit"] == "10"
      refute Map.has_key?(conn.query_params, "organization_id")

      json_response(conn, 200, %{
        "data" => [
          %{"id" => "om_1", "organization_id" => "org_active", "status" => "active"},
          %{"id" => "om_2", "organization_id" => "org_inactive", "status" => "inactive"},
          %{"id" => "om_3", "organization_id" => "org_unknown"}
        ]
      })
    end)

    assert {:ok, memberships} = AccountsWorkOS.list_user_organization_memberships("user_123")

    assert Enum.map(memberships, fn membership ->
             membership["organization_id"]
           end) == ["org_active", "org_unknown"]
  end

  test "get_user_organization_membership/2 returns forbidden when membership is missing" do
    Req.Test.expect(:workos_api, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/user_management/organization_memberships"
      json_response(conn, 200, %{"data" => []})
    end)

    assert {:error, :forbidden} =
             AccountsWorkOS.get_user_organization_membership("user_123", "org_404")
  end

  test "user_has_organization_membership?/2 checks active membership in organization" do
    Req.Test.expect(:workos_api, fn conn ->
      conn = fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/user_management/organization_memberships"
      assert conn.query_params["user_id"] == "user_123"
      assert conn.query_params["organization_id"] == "org_123"

      json_response(conn, 200, %{
        "data" => [
          %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"}
        ]
      })
    end)

    assert {:ok, true} = AccountsWorkOS.user_has_organization_membership?("user_123", "org_123")
  end

  defp decode_json(conn) do
    conn
    |> Req.Test.raw_body()
    |> Jason.decode!()
  end

  defp json_response(conn, status, body) do
    conn
    |> put_status(status)
    |> Req.Test.json(body)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
