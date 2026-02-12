defmodule FizzWeb.WorkOSAuthControllerTest do
  use FizzWeb.ConnCase, async: false

  import Fizz.AccountsFixtures

  alias Fizz.Accounts
  alias Fizz.Accounts.User
  alias Fizz.Repo

  defmodule ReqMock do
    def request(opts) do
      send(self(), {:workos_http_request, opts})
      code = get_in(opts, [:json, :code])

      case code do
        "ok-code" ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "user" => %{
                 "id" => "user_workos_123",
                 "email" => "sso-user@example.com",
                 "email_verified" => true
               },
               "access_token" => unsigned_jwt("user_workos_123", "session_workos_123"),
               "refresh_token" => "refresh_workos_123",
               "authentication_method" => "sso"
             }
           }}

        "conflict-code" ->
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

        _ ->
          {:ok,
           %Req.Response{
             status: 400,
             body: %{"code" => "invalid_grant", "message" => "Invalid authorization code"}
           }}
      end
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
    previous_provider = Application.get_env(:fizz, :workos_authkit_provider)

    Application.put_env(:fizz, :workos_http_client_module, ReqMock)
    Application.put_env(:fizz, :workos_authkit_provider, "authkit")

    on_exit(fn ->
      if previous_http_client do
        Application.put_env(:fizz, :workos_http_client_module, previous_http_client)
      else
        Application.delete_env(:fizz, :workos_http_client_module)
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

    redirect_url = redirected_to(conn)
    query = redirect_url |> URI.parse() |> Map.get(:query, "") |> URI.decode_query()

    assert String.starts_with?(redirect_url, "https://api.workos.com/user_management/authorize")
    assert query["provider"] == "authkit"
    assert query["code_challenge_method"] == "S256"
    assert is_binary(query["state"])
    assert byte_size(query["state"]) > 10
    assert is_binary(query["code_challenge"])
    assert get_session(conn, :workos_auth_state) == query["state"]
    assert is_binary(get_session(conn, :workos_pkce_verifier))
  end

  test "GET /users/log-in redirects directly to WorkOS hosted UI", %{conn: conn} do
    conn = get(conn, ~p"/users/log-in")

    redirect_url = redirected_to(conn)
    query = redirect_url |> URI.parse() |> Map.get(:query, "") |> URI.decode_query()

    assert String.starts_with?(redirect_url, "https://api.workos.com/user_management/authorize")
    assert query["provider"] == "authkit"
    assert query["code_challenge_method"] == "S256"
    assert is_binary(query["state"])
    assert byte_size(query["state"]) > 10
    assert is_binary(query["code_challenge"])
    assert get_session(conn, :workos_auth_state) == query["state"]
    assert is_binary(get_session(conn, :workos_pkce_verifier))
  end

  test "GET /auth/workos/callback logs in user for valid code and state", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{
        workos_auth_state: "known-state",
        workos_pkce_verifier: "known-verifier"
      })
      |> get(~p"/auth/workos/callback", %{"code" => "ok-code", "state" => "known-state"})

    assert_receive {:workos_http_request, params}
    assert params[:json][:code] == "ok-code"
    assert params[:json][:code_verifier] == "known-verifier"
    assert params[:json][:ip_address]

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :workos_session_id) == "session_workos_123"
    assert get_session(conn, :workos_user_id) == "user_workos_123"
    assert get_session(conn, :workos_access_token)
    assert get_session(conn, :workos_refresh_token)

    assert get_session(conn, :live_socket_id) ==
             "workos_sessions:#{Base.url_encode64("session_workos_123", padding: false)}"

    refute get_session(conn, :workos_auth_state)
    refute get_session(conn, :workos_pkce_verifier)

    assert user = Accounts.get_user_by_workos_user_id("user_workos_123")
    assert user.email == "sso-user@example.com"
    assert user.confirmed_at
  end

  test "GET /auth/workos/callback rejects invalid state", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{
        workos_auth_state: "known-state",
        workos_pkce_verifier: "known-verifier"
      })
      |> get(~p"/auth/workos/callback", %{"code" => "ok-code", "state" => "wrong-state"})

    assert redirected_to(conn) == ~p"/"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Your login session expired. Please try again."

    refute get_session(conn, :workos_session_id)
  end

  test "GET /auth/workos/callback handles WorkOS account conflict", %{conn: conn} do
    existing_user = user_fixture(%{email: "conflict@example.com"})

    {:ok, _existing_user} =
      existing_user
      |> User.workos_changeset(%{workos_user_id: "user_existing"})
      |> Repo.update()

    conn =
      conn
      |> init_test_session(%{
        workos_auth_state: "known-state",
        workos_pkce_verifier: "known-verifier"
      })
      |> get(~p"/auth/workos/callback", %{"code" => "conflict-code", "state" => "known-state"})

    assert redirected_to(conn) == ~p"/"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "An account conflict was detected for this WorkOS identity. Contact support."

    refute get_session(conn, :workos_session_id)
  end
end
