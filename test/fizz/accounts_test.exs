defmodule Fizz.AccountsTest do
  use Fizz.DataCase

  alias Fizz.Accounts
  alias Fizz.Accounts.User
  alias Fizz.Repo

  import Fizz.AccountsFixtures

  defmodule ReqMock do
    def request(opts) do
      send(self(), {:workos_http_request, opts})

      case {opts[:method], opts[:url]} do
        {:post, "/user_management/authenticate"} ->
          authenticate_response(opts[:json][:code])

        {:post, "/organizations"} ->
          create_organization_response(opts[:json])

        {:post, "/user_management/organization_memberships"} ->
          create_membership_response(opts[:json])

        {:get, "/user_management/organization_memberships"} ->
          list_memberships_response(opts[:params])

        _ ->
          {:ok, %Req.Response{status: 404, body: %{"message" => "Not found"}}}
      end
    end

    defp create_organization_response(%{name: name}) do
      org_id = "org_#{System.unique_integer([:positive])}"

      {:ok,
       %Req.Response{
         status: 201,
         body: %{
           "id" => org_id,
           "name" => name
         }
       }}
    end

    defp create_organization_response(_) do
      {:ok,
       %Req.Response{
         status: 422,
         body: %{"code" => "invalid_request", "message" => "Name is required"}
       }}
    end

    defp create_membership_response(%{user_id: user_id, organization_id: org_id}) do
      {:ok,
       %Req.Response{
         status: 201,
         body: %{
           "id" => "om_#{System.unique_integer([:positive])}",
           "user_id" => user_id,
           "organization_id" => org_id,
           "status" => "active",
           "role" => %{"slug" => "owner"}
         }
       }}
    end

    defp create_membership_response(_) do
      {:ok,
       %Req.Response{
         status: 422,
         body: %{"code" => "invalid_request", "message" => "Invalid membership params"}
       }}
    end

    defp list_memberships_response(params) do
      user_id = Keyword.get(params, :user_id) || params[:user_id]

      if user_id == "user_workos_with_orgs" do
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "data" => [
               %{
                 "id" => "om_existing",
                 "user_id" => "user_workos_with_orgs",
                 "organization_id" => "org_existing_1",
                 "status" => "active",
                 "role" => %{"slug" => "owner"},
                 "organization" => %{"name" => "Existing Org"}
               }
             ]
           }
         }}
      else
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"data" => []}
         }}
      end
    end

    defp authenticate_response("new-user") do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "user" => %{
             "id" => "user_workos_new",
             "email" => "new-user@example.com",
             "email_verified" => true
           },
           "access_token" => unsigned_jwt("user_workos_new", "session_workos_new"),
           "refresh_token" => "refresh_workos_new",
           "authentication_method" => "sso"
         }
       }}
    end

    defp authenticate_response("existing-id") do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "user" => %{
             "id" => "user_workos_existing",
             "email" => "updated@example.com",
             "email_verified" => true
           },
           "access_token" => unsigned_jwt("user_workos_existing", "session_workos_existing"),
           "refresh_token" => "refresh_workos_existing",
           "authentication_method" => "sso"
         }
       }}
    end

    defp authenticate_response("link-existing-email") do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "user" => %{
             "id" => "user_workos_linked",
             "email" => "link-existing@example.com",
             "email_verified" => false
           },
           "access_token" => unsigned_jwt("user_workos_linked", "session_workos_linked"),
           "refresh_token" => "refresh_workos_linked",
           "authentication_method" => "sso"
         }
       }}
    end

    defp authenticate_response("conflict-email") do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "user" => %{
             "id" => "user_workos_conflict",
             "email" => "conflict@example.com",
             "email_verified" => true
           },
           "access_token" => unsigned_jwt("user_workos_conflict", "session_workos_conflict"),
           "refresh_token" => "refresh_workos_conflict",
           "authentication_method" => "sso"
         }
       }}
    end

    defp authenticate_response(_code) do
      {:ok,
       %Req.Response{
         status: 400,
         body: %{"code" => "invalid_grant", "message" => "Invalid authorization code"}
       }}
    end

    defp unsigned_jwt(sub, sid) do
      header = Base.url_encode64(~s({"alg":"none","typ":"JWT"}), padding: false)

      payload =
        Base.url_encode64(
          Jason.encode!(%{
            sub: sub,
            sid: sid,
            exp: System.os_time(:second) + 3600
          }),
          padding: false
        )

      "#{header}.#{payload}."
    end
  end

  setup do
    previous_http_client = Application.get_env(:fizz, :workos_http_client_module)
    previous_workos_client = Application.get_env(:workos, WorkOS.Client)

    Application.put_env(:fizz, :workos_http_client_module, ReqMock)

    Application.put_env(:workos, WorkOS.Client,
      api_key: "sk_test_123",
      client_id: "client_test_123",
      client: Fizz.Accounts.WorkOS.ReqClient
    )

    on_exit(fn ->
      if previous_http_client do
        Application.put_env(:fizz, :workos_http_client_module, previous_http_client)
      else
        Application.delete_env(:fizz, :workos_http_client_module)
      end

      if previous_workos_client do
        Application.put_env(:workos, WorkOS.Client, previous_workos_client)
      else
        Application.delete_env(:workos, WorkOS.Client)
      end
    end)

    :ok
  end

  describe "user lookup functions" do
    test "get_user_by_email/1 returns nil for unknown email" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "get_user_by_email/1 returns the user for a known email" do
      %{id: id, email: email} = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(email)
    end

    test "get_user_by_workos_user_id/1 returns nil for unknown id" do
      refute Accounts.get_user_by_workos_user_id("user_workos_missing")
    end

    test "get_user_by_workos_user_id/1 returns the user for a known id" do
      %{id: id} = user_fixture(%{workos_user_id: "user_workos_lookup"})
      assert %User{id: ^id} = Accounts.get_user_by_workos_user_id("user_workos_lookup")
    end

    test "get_user!/1 raises for unknown id" do
      unknown_id = Ecto.UUID.generate()

      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(unknown_id)
      end
    end

    test "get_user!/1 returns a user by id" do
      %{id: id} = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(id)
    end
  end

  describe "authenticate_user_with_workos_code/2" do
    test "creates a new local user when workos identity is unknown" do
      assert {:ok, user} =
               Accounts.authenticate_user_with_workos_code("new-user",
                 code_verifier: "test_verifier",
                 ip_address: "127.0.0.1",
                 user_agent: "test-agent"
               )

      assert user.workos_user_id == "user_workos_new"
      assert user.email == "new-user@example.com"
      assert user.confirmed_at

      assert_receive {:workos_http_request, request}
      assert request[:json][:code] == "new-user"
      assert request[:json][:ip_address] == "127.0.0.1"
      assert request[:json][:user_agent] == "test-agent"
    end

    test "updates a local user matched by workos_user_id" do
      user_fixture(%{email: "before@example.com", workos_user_id: "user_workos_existing"})

      assert {:ok, user} =
               Accounts.authenticate_user_with_workos_code("existing-id",
                 code_verifier: "test_verifier"
               )

      assert user.workos_user_id == "user_workos_existing"
      assert user.email == "updated@example.com"
      assert user.confirmed_at
    end

    test "links an existing local email to a new workos_user_id" do
      existing_user = Repo.insert!(%User{email: "link-existing@example.com"})

      assert {:ok, user} =
               Accounts.authenticate_user_with_workos_code("link-existing-email",
                 code_verifier: "test_verifier"
               )

      assert user.id == existing_user.id
      assert user.workos_user_id == "user_workos_linked"
      assert user.email == "link-existing@example.com"
      refute user.confirmed_at
    end

    test "returns conflict when email belongs to another workos identity" do
      user_fixture(%{email: "conflict@example.com", workos_user_id: "user_workos_local"})

      assert {:error, :workos_account_conflict} =
               Accounts.authenticate_user_with_workos_code("conflict-email",
                 code_verifier: "test_verifier"
               )
    end

    test "returns the underlying workos error when code exchange fails" do
      assert {:error, {:workos_error, "invalid_grant", "Invalid authorization code", 400}} =
               Accounts.authenticate_user_with_workos_code("invalid-code",
                 code_verifier: "test_verifier"
               )
    end
  end

  describe "authenticate_user_with_workos_code_and_session/2" do
    test "returns the resolved user and WorkOS session id" do
      assert {:ok, %{user: user, workos_session_id: "session_workos_new"}} =
               Accounts.authenticate_user_with_workos_code_and_session("new-user",
                 code_verifier: "test_verifier"
               )

      assert user.workos_user_id == "user_workos_new"
    end

    test "returns the WorkOS session payload when tokens are available" do
      assert {:ok,
              %{workos_session: workos_session, workos_session_id: "session_workos_existing"}} =
               Accounts.authenticate_user_with_workos_code_and_session("existing-id",
                 code_verifier: "test_verifier"
               )

      assert workos_session.workos_user_id == "user_workos_existing"
      assert is_binary(workos_session.access_token)
      assert is_binary(workos_session.refresh_token)
    end
  end

  describe "upsert_user_from_workos_profile/1" do
    test "creates a user when workos_user_id does not exist locally" do
      assert {:ok, user} =
               Accounts.upsert_user_from_workos_profile(%{
                 id: "user_workos_webhook_created",
                 email: "webhook-created@example.com",
                 email_verified: true
               })

      assert user.workos_user_id == "user_workos_webhook_created"
      assert user.email == "webhook-created@example.com"
      assert user.confirmed_at
    end

    test "updates user attributes for an existing workos_user_id" do
      existing =
        user_fixture(%{
          workos_user_id: "user_workos_webhook_existing",
          email: "before-webhook@example.com"
        })

      assert {:ok, updated} =
               Accounts.upsert_user_from_workos_profile(%{
                 id: "user_workos_webhook_existing",
                 email: "after-webhook@example.com",
                 email_verified: true
               })

      assert updated.id == existing.id
      assert updated.email == "after-webhook@example.com"
      assert updated.confirmed_at
    end

    test "returns error for invalid payload" do
      assert {:error, :invalid_workos_user_profile} =
               Accounts.upsert_user_from_workos_profile(%{id: "only-id"})
    end
  end

  describe "delete_user_by_workos_user_id/1" do
    test "deletes the local user when present" do
      user_fixture(%{workos_user_id: "user_workos_webhook_delete"})

      assert :ok = Accounts.delete_user_by_workos_user_id("user_workos_webhook_delete")
      refute Accounts.get_user_by_workos_user_id("user_workos_webhook_delete")
    end

    test "returns ok when local user does not exist" do
      assert :ok = Accounts.delete_user_by_workos_user_id("user_workos_missing_delete")
    end
  end

  describe "revoke_user_sessions_by_workos_user_id/1" do
    test "returns ok when local user exists" do
      user_fixture(%{workos_user_id: "user_workos_revoke"})
      assert :ok = Accounts.revoke_user_sessions_by_workos_user_id("user_workos_revoke")
    end

    test "returns ok when local user does not exist" do
      assert :ok = Accounts.revoke_user_sessions_by_workos_user_id("user_workos_missing_revoke")
    end

    test "returns error for invalid workos_user_id" do
      assert {:error, :invalid_workos_user_id} =
               Accounts.revoke_user_sessions_by_workos_user_id(nil)
    end
  end

  describe "create_organization/3" do
    test "creates a WorkOS organization and owner membership" do
      scope = user_scope_fixture(user_fixture(%{workos_user_id: "user_workos_org_creator"}))

      assert {:ok, %{organization_id: org_id, name: "Test Org"}} =
               Accounts.create_organization(scope, %{name: "Test Org"})

      assert is_binary(org_id)

      # Verify the organization creation request was made
      assert_receive {:workos_http_request, create_org_req}
      assert create_org_req[:method] == :post
      assert create_org_req[:url] == "/organizations"
      assert create_org_req[:json][:name] == "Test Org"

      # Verify the membership creation request was made
      assert_receive {:workos_http_request, create_membership_req}
      assert create_membership_req[:method] == :post
      assert create_membership_req[:url] == "/user_management/organization_memberships"
      assert create_membership_req[:json][:user_id] == "user_workos_org_creator"
      assert create_membership_req[:json][:role_slug] == "owner"
    end

    test "returns error when user has no workos_user_id" do
      user = Repo.insert!(%User{email: "no-workos@example.com"})
      scope = user_scope_fixture(user)

      assert {:error, :missing_workos_user_id} =
               Accounts.create_organization(scope, %{name: "Test Org"})
    end

    test "returns error when unauthenticated" do
      assert {:error, :unauthenticated} =
               Accounts.create_organization(nil, %{name: "Test Org"})
    end
  end

  describe "ensure_personal_organization/1" do
    test "returns existing organizations when user has them" do
      scope = user_scope_fixture(user_fixture(%{workos_user_id: "user_workos_with_orgs"}))

      orgs = Accounts.ensure_personal_organization(scope)

      assert length(orgs) == 1
      assert hd(orgs).organization_id == "org_existing_1"
      assert hd(orgs).organization_name == "Existing Org"
    end

    test "creates a personal organization when user has none" do
      user = user_fixture(%{email: "alice@example.com", workos_user_id: "user_workos_no_orgs"})
      scope = user_scope_fixture(user)

      orgs = Accounts.ensure_personal_organization(scope)

      assert length(orgs) == 1
      assert hd(orgs).organization_name == "alice's Organization"
      assert hd(orgs).role == :owner
    end

    test "returns empty list for nil scope" do
      assert Accounts.ensure_personal_organization(nil) == []
    end
  end
end
