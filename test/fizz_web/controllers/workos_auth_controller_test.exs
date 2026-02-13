defmodule FizzWeb.WorkOSAuthControllerTest do
  use FizzWeb.ConnCase, async: false

  import Fizz.AccountsFixtures

  alias Fizz.Accounts
  alias Fizz.Accounts.User
  alias Fizz.Repo

  setup do
    previous_workos_client_module = Application.get_env(:fizz, :workos_client_module)
    previous_provider = Application.get_env(:fizz, :workos_authkit_provider)
    mock_store = start_supervised!({Agent, fn -> %{} end})

    Fizz.WorkOSClientMock.configure(self(), mock_store)
    Application.put_env(:fizz, :workos_client_module, Fizz.WorkOSClientMock)
    Application.put_env(:fizz, :workos_authkit_provider, "authkit")

    Fizz.WorkOSClientMock.put_response(:authorization_url, fn params ->
      query =
        %{
          "provider" => params[:provider],
          "code_challenge_method" => params[:code_challenge_method],
          "state" => params[:state],
          "code_challenge" => params[:code_challenge]
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      {:ok, "https://api.workos.com/user_management/authorize?#{URI.encode_query(query)}"}
    end)

    on_exit(fn ->
      restore_env(:fizz, :workos_client_module, previous_workos_client_module)
      restore_env(:fizz, :workos_authkit_provider, previous_provider)
      Fizz.WorkOSClientMock.reset()
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
    Fizz.WorkOSClientMock.put_response(:authenticate_with_code, fn _params ->
      {:ok,
       authentication_payload(
         "user_workos_123",
         "sso-user@example.com",
         true,
         "session_workos_123",
         "refresh_workos_123"
       )}
    end)

    conn =
      conn
      |> init_test_session(%{
        workos_auth_state: "known-state",
        workos_pkce_verifier: "known-verifier"
      })
      |> get(~p"/auth/workos/callback", %{"code" => "ok-code", "state" => "known-state"})

    assert_receive {:workos_client_call, :authenticate_with_code, [params]}
    assert params[:code] == "ok-code"
    assert params[:code_verifier] == "known-verifier"
    assert is_binary(params[:ip_address])

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
    Fizz.WorkOSClientMock.put_response(:authenticate_with_code, fn _params ->
      {:ok,
       authentication_payload(
         "user_workos_conflict",
         "conflict@example.com",
         true,
         "session_workos_conflict",
         "refresh_workos_conflict"
       )}
    end)

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
