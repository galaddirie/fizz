defmodule FizzWeb.WorkOSAuthControllerTest do
  use FizzWeb.ConnCase, async: false

  import Fizz.AccountsFixtures

  alias Fizz.Accounts
  alias Fizz.Accounts.User
  alias Fizz.Repo

  defmodule UserManagementMock do
    def get_authorization_url(params) do
      send(self(), {:workos_authorization_url, params})
      {:ok, "https://auth.workos.test/authorize?state=#{params[:state]}"}
    end

    def authenticate_with_code(params) do
      send(self(), {:workos_authenticate_with_code, params})

      case params[:code] do
        "ok-code" ->
          {:ok,
           %WorkOS.UserManagement.Authentication{
             user: %{
               "id" => "user_workos_123",
               "email" => "sso-user@example.com",
               "email_verified" => true
             },
             access_token: unsigned_jwt_with_sid("session_workos_123"),
             authentication_method: "sso"
           }}

        "conflict-code" ->
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

    def create_user(_params), do: {:error, :not_implemented}
    def create_organization_membership(_params), do: {:error, :not_implemented}
  end

  setup do
    previous_module = Application.get_env(:fizz, :workos_user_management_module)
    previous_provider = Application.get_env(:fizz, :workos_authkit_provider)

    Application.put_env(:fizz, :workos_user_management_module, UserManagementMock)
    Application.put_env(:fizz, :workos_authkit_provider, "authkit")

    on_exit(fn ->
      if previous_module do
        Application.put_env(:fizz, :workos_user_management_module, previous_module)
      else
        Application.delete_env(:fizz, :workos_user_management_module)
      end

      if previous_provider do
        Application.put_env(:fizz, :workos_authkit_provider, previous_provider)
      else
        Application.delete_env(:fizz, :workos_authkit_provider)
      end
    end)

    :ok
  end

  test "GET /auth/workos redirects to WorkOS hosted UI", %{conn: conn} do
    conn = get(conn, ~p"/auth/workos")

    assert_receive {:workos_authorization_url, params}
    assert params[:provider] == "authkit"
    assert is_binary(params[:state])
    assert byte_size(params[:state]) > 10
    assert String.ends_with?(params[:redirect_uri], "/auth/workos/callback")

    assert redirected_to(conn) =~ "https://auth.workos.test/authorize"
    assert get_session(conn, :workos_auth_state) == params[:state]
  end

  test "GET /users/log-in redirects directly to WorkOS hosted UI", %{conn: conn} do
    conn = get(conn, ~p"/users/log-in")

    assert_receive {:workos_authorization_url, params}
    assert params[:provider] == "authkit"
    assert is_binary(params[:state])
    assert byte_size(params[:state]) > 10
    assert String.ends_with?(params[:redirect_uri], "/auth/workos/callback")

    assert redirected_to(conn) =~ "https://auth.workos.test/authorize"
    assert get_session(conn, :workos_auth_state) == params[:state]
  end

  test "GET /auth/workos/callback logs in user for valid code and state", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{workos_auth_state: "known-state"})
      |> get(~p"/auth/workos/callback", %{"code" => "ok-code", "state" => "known-state"})

    assert_receive {:workos_authenticate_with_code, params}
    assert params[:code] == "ok-code"
    assert params[:ip_address]

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_token)
    assert get_session(conn, :workos_session_id) == "session_workos_123"
    refute get_session(conn, :workos_auth_state)

    assert user = Accounts.get_user_by_workos_user_id("user_workos_123")
    assert user.email == "sso-user@example.com"
    assert user.confirmed_at
  end

  test "GET /auth/workos/callback rejects invalid state", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{workos_auth_state: "known-state"})
      |> get(~p"/auth/workos/callback", %{"code" => "ok-code", "state" => "wrong-state"})

    assert redirected_to(conn) == ~p"/"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Your login session expired. Please try again."

    refute get_session(conn, :user_token)
  end

  test "GET /auth/workos/callback handles WorkOS account conflict", %{conn: conn} do
    existing_user = user_fixture(%{email: "conflict@example.com"})

    {:ok, _existing_user} =
      existing_user
      |> User.workos_changeset(%{workos_user_id: "user_existing"})
      |> Repo.update()

    conn =
      conn
      |> init_test_session(%{workos_auth_state: "known-state"})
      |> get(~p"/auth/workos/callback", %{"code" => "conflict-code", "state" => "known-state"})

    assert redirected_to(conn) == ~p"/"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "An account conflict was detected for this WorkOS identity. Contact support."

    refute get_session(conn, :user_token)
  end
end
