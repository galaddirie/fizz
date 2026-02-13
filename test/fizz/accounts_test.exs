defmodule Fizz.AccountsTest do
  use Fizz.DataCase

  alias Fizz.Accounts
  alias Fizz.Accounts.User
  alias Fizz.Repo

  import Fizz.AccountsFixtures

  setup do
    previous_module = Application.get_env(:fizz, :workos_client_module)
    mock_store = start_supervised!({Agent, fn -> %{} end})

    Fizz.WorkOSClientMock.configure(self(), mock_store)
    Application.put_env(:fizz, :workos_client_module, Fizz.WorkOSClientMock)

    on_exit(fn ->
      restore_env(:fizz, :workos_client_module, previous_module)
      Fizz.WorkOSClientMock.reset()
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
      put_authenticate_with_code_response(fn params ->
        send(self(), {:workos_authenticate_with_code, params})

        {:ok,
         authentication_payload(
           "user_workos_new",
           "new-user@example.com",
           true,
           "session_workos_new",
           "refresh_workos_new"
         )}
      end)

      assert {:ok, user} =
               Accounts.authenticate_user_with_workos_code("new-user",
                 ip_address: "127.0.0.1",
                 user_agent: "test-agent"
               )

      assert user.workos_user_id == "user_workos_new"
      assert user.email == "new-user@example.com"
      assert user.confirmed_at

      assert_receive {:workos_authenticate_with_code, params}
      assert params[:code] == "new-user"
      assert params[:ip_address] == "127.0.0.1"
      assert params[:user_agent] == "test-agent"
    end

    test "updates a local user matched by workos_user_id" do
      put_authenticate_with_code_response(fn _params ->
        {:ok,
         authentication_payload(
           "user_workos_existing",
           "updated@example.com",
           true,
           "session_workos_existing",
           "refresh_workos_existing"
         )}
      end)

      user_fixture(%{email: "before@example.com", workos_user_id: "user_workos_existing"})

      assert {:ok, user} = Accounts.authenticate_user_with_workos_code("existing-id")
      assert user.workos_user_id == "user_workos_existing"
      assert user.email == "updated@example.com"
      assert user.confirmed_at
    end

    test "links an existing local email to a new workos_user_id" do
      put_authenticate_with_code_response(fn _params ->
        {:ok,
         authentication_payload(
           "user_workos_linked",
           "link-existing@example.com",
           false,
           "session_workos_linked",
           "refresh_workos_linked"
         )}
      end)

      existing_user = Repo.insert!(%User{email: "link-existing@example.com"})

      assert {:ok, user} = Accounts.authenticate_user_with_workos_code("link-existing-email")
      assert user.id == existing_user.id
      assert user.workos_user_id == "user_workos_linked"
      assert user.email == "link-existing@example.com"
      refute user.confirmed_at
    end

    test "returns conflict when email belongs to another workos identity" do
      put_authenticate_with_code_response(fn _params ->
        {:ok,
         authentication_payload(
           "user_workos_conflict",
           "conflict@example.com",
           true,
           "session_workos_conflict",
           "refresh_workos_conflict"
         )}
      end)

      user_fixture(%{email: "conflict@example.com", workos_user_id: "user_workos_local"})

      assert {:error, :workos_account_conflict} =
               Accounts.authenticate_user_with_workos_code("conflict-email")
    end

    test "returns the underlying workos error when code exchange fails" do
      put_authenticate_with_code_response(fn _params ->
        {:error, {:workos_error, "invalid_grant", "Invalid authorization code"}}
      end)

      assert {:error, {:workos_error, "invalid_grant", "Invalid authorization code"}} =
               Accounts.authenticate_user_with_workos_code("invalid-code")
    end
  end

  describe "authenticate_user_with_workos_code_and_session/2" do
    test "returns the resolved user and WorkOS session id" do
      put_authenticate_with_code_response(fn _params ->
        {:ok,
         authentication_payload(
           "user_workos_new",
           "new-user@example.com",
           true,
           "session_workos_new",
           "refresh_workos_new"
         )}
      end)

      assert {:ok, %{user: user, workos_session_id: "session_workos_new"}} =
               Accounts.authenticate_user_with_workos_code_and_session("new-user")

      assert user.workos_user_id == "user_workos_new"
    end

    test "returns the WorkOS session payload when tokens are available" do
      put_authenticate_with_code_response(fn _params ->
        {:ok,
         authentication_payload(
           "user_workos_existing",
           "updated@example.com",
           true,
           "session_workos_existing",
           "refresh_workos_existing"
         )}
      end)

      assert {:ok,
              %{workos_session: workos_session, workos_session_id: "session_workos_existing"}} =
               Accounts.authenticate_user_with_workos_code_and_session("existing-id")

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

  defp put_authenticate_with_code_response(response) do
    Fizz.WorkOSClientMock.put_response(:authenticate_with_code, response)
  end

  defp authentication_payload(id, email, email_verified, session_id, refresh_token) do
    %WorkOS.UserManagement.Authentication{
      user: %{
        "id" => id,
        "email" => email,
        "email_verified" => email_verified
      },
      access_token: unsigned_jwt(id, session_id),
      refresh_token: refresh_token,
      authentication_method: "sso"
    }
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

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
