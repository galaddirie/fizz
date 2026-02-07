defmodule Fizz.AccountsTest do
  use Fizz.DataCase

  alias Fizz.Accounts
  alias Fizz.Accounts.{User, UserToken}
  alias Fizz.Repo

  import Fizz.AccountsFixtures

  defmodule UserManagementMock do
    def get_authorization_url(_params), do: {:ok, "https://auth.workos.test/authorize"}
    def create_user(_params), do: {:error, :not_implemented}
    def create_organization_membership(_params), do: {:error, :not_implemented}

    def authenticate_with_code(params) do
      send(self(), {:workos_authenticate_with_code, params})

      case params[:code] do
        "new-user" ->
          {:ok,
           %WorkOS.UserManagement.Authentication{
             user: %{
               "id" => "user_workos_new",
               "email" => "new-user@example.com",
               "email_verified" => true
             },
             access_token: unsigned_jwt_with_sid("session_workos_new"),
             authentication_method: "sso"
           }}

        "existing-id" ->
          {:ok,
           %WorkOS.UserManagement.Authentication{
             user: %{
               "id" => "user_workos_existing",
               "email" => "updated@example.com",
               "email_verified" => true
             },
             authentication_method: "sso"
           }}

        "link-existing-email" ->
          {:ok,
           %WorkOS.UserManagement.Authentication{
             user: %{
               "id" => "user_workos_linked",
               "email" => "link-existing@example.com",
               "email_verified" => false
             },
             authentication_method: "sso"
           }}

        "conflict-email" ->
          {:ok,
           %WorkOS.UserManagement.Authentication{
             user: %{
               "id" => "user_workos_conflict",
               "email" => "conflict@example.com",
               "email_verified" => true
             },
             authentication_method: "sso"
           }}

        _ ->
          {:error, {:workos_error, "invalid_grant", "Invalid authorization code"}}
      end
    end

    defp unsigned_jwt_with_sid(sid) do
      header = Base.url_encode64(~s({"alg":"none","typ":"JWT"}), padding: false)
      payload = Base.url_encode64(Jason.encode!(%{sid: sid}), padding: false)
      "#{header}.#{payload}."
    end
  end

  setup do
    previous_module = Application.get_env(:fizz, :workos_user_management_module)
    Application.put_env(:fizz, :workos_user_management_module, UserManagementMock)

    on_exit(fn ->
      if previous_module do
        Application.put_env(:fizz, :workos_user_management_module, previous_module)
      else
        Application.delete_env(:fizz, :workos_user_management_module)
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
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(-1)
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
      user_fixture(%{email: "before@example.com", workos_user_id: "user_workos_existing"})

      assert {:ok, user} = Accounts.authenticate_user_with_workos_code("existing-id")
      assert user.workos_user_id == "user_workos_existing"
      assert user.email == "updated@example.com"
      assert user.confirmed_at
    end

    test "links an existing local email to a new workos_user_id" do
      existing_user = Repo.insert!(%User{email: "link-existing@example.com"})

      assert {:ok, user} = Accounts.authenticate_user_with_workos_code("link-existing-email")
      assert user.id == existing_user.id
      assert user.workos_user_id == "user_workos_linked"
      assert user.email == "link-existing@example.com"
      refute user.confirmed_at
    end

    test "returns conflict when email belongs to another workos identity" do
      user_fixture(%{email: "conflict@example.com", workos_user_id: "user_workos_local"})

      assert {:error, :workos_account_conflict} =
               Accounts.authenticate_user_with_workos_code("conflict-email")
    end

    test "returns the underlying workos error when code exchange fails" do
      assert {:error, {:workos_error, "invalid_grant", "Invalid authorization code"}} =
               Accounts.authenticate_user_with_workos_code("invalid-code")
    end
  end

  describe "authenticate_user_with_workos_code_and_session/2" do
    test "returns the resolved user and WorkOS session id" do
      assert {:ok, %{user: user, workos_session_id: "session_workos_new"}} =
               Accounts.authenticate_user_with_workos_code_and_session("new-user")

      assert user.workos_user_id == "user_workos_new"
    end

    test "returns nil for workos_session_id when the access token is unavailable" do
      assert {:ok, %{workos_session_id: nil}} =
               Accounts.authenticate_user_with_workos_code_and_session("existing-id")
    end
  end

  describe "generate_user_session_token/1" do
    test "stores a unique session token" do
      token = Accounts.generate_user_session_token(user_fixture())
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.authenticated_at

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          authenticated_at: DateTime.utc_now(:second)
        })
      end
    end

    test "copies authenticated_at from the given user when present" do
      user = %{user_fixture() | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.authenticated_at == user.authenticated_at
      assert DateTime.compare(user_token.inserted_at, user.authenticated_at) == :gt
    end
  end

  describe "get_user_by_session_token/1" do
    test "returns user and inserted_at when token is valid" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      assert {session_user, token_inserted_at} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
      assert token_inserted_at
    end

    test "returns nil for an invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "returns nil for an expired token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      offset_user_token(token, -15, :day)

      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token and invalidates the session" do
      token = Accounts.generate_user_session_token(user_fixture())
      assert :ok = Accounts.delete_user_session_token(token)
      refute Accounts.get_user_by_session_token(token)
    end
  end
end
