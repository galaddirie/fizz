defmodule FizzWeb.UserAuthTest do
  use FizzWeb.ConnCase, async: true

  alias Phoenix.LiveView
  alias Fizz.Accounts.Scope
  alias FizzWeb.UserAuth

  import Fizz.AccountsFixtures

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, FizzWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{user: %{user_fixture() | authenticated_at: DateTime.utc_now(:second)}, conn: conn}
  end

  describe "log_in_user/3" do
    test "stores the WorkOS session in the session", %{conn: conn, user: user} do
      conn = UserAuth.log_in_user(conn, user, %{workos_session: workos_session(user)})

      assert get_session(conn, :workos_user_id) == user.workos_user_id
      assert get_session(conn, :workos_session_id) == "session_#{user.id}"
      assert get_session(conn, :workos_access_token)
      assert get_session(conn, :workos_refresh_token)

      assert get_session(conn, :live_socket_id) ==
               "workos_sessions:#{Base.url_encode64("session_#{user.id}", padding: false)}"

      assert redirected_to(conn) == ~p"/"
    end

    test "clears everything previously stored in the session", %{conn: conn, user: user} do
      conn =
        conn
        |> put_session(:to_be_removed, "value")
        |> UserAuth.log_in_user(user, %{workos_session: workos_session(user)})

      refute get_session(conn, :to_be_removed)
    end

    test "keeps session when re-authenticating", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> put_session(:to_be_removed, "value")
        |> UserAuth.log_in_user(user, %{workos_session: workos_session(user)})

      assert get_session(conn, :to_be_removed)
    end

    test "clears session when user does not match when re-authenticating", %{
      conn: conn,
      user: user
    } do
      other_user = user_fixture()

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(other_user))
        |> put_session(:to_be_removed, "value")
        |> UserAuth.log_in_user(user, %{workos_session: workos_session(user)})

      refute get_session(conn, :to_be_removed)
    end

    test "redirects to the configured path", %{conn: conn, user: user} do
      conn =
        conn
        |> put_session(:user_return_to, "/hello")
        |> UserAuth.log_in_user(user, %{workos_session: workos_session(user)})

      assert redirected_to(conn) == "/hello"
    end

    test "redirects to signed in path when user is already logged in", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> UserAuth.log_in_user(user, %{workos_session: workos_session(user)})

      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "logout_user/1" do
    test "erases WorkOS session fields", %{conn: conn, user: user} do
      return_to = FizzWeb.Endpoint.url() <> "/"

      expected_logout_url =
        "https://api.workos.com/user_management/sessions/logout?" <>
          URI.encode_query(%{session_id: "session_#{user.id}", return_to: return_to})

      conn =
        conn
        |> put_workos_session(user)
        |> UserAuth.log_out_user()

      refute get_session(conn, :workos_user_id)
      refute get_session(conn, :workos_session_id)
      refute get_session(conn, :workos_access_token)
      refute get_session(conn, :workos_refresh_token)
      refute get_session(conn, :live_socket_id)
      assert redirected_to(conn) == expected_logout_url
    end

    test "broadcasts to the given live_socket_id", %{conn: conn} do
      live_socket_id = "workos_sessions:abcdef-session"
      FizzWeb.Endpoint.subscribe(live_socket_id)

      conn
      |> put_session(:live_socket_id, live_socket_id)
      |> UserAuth.log_out_user()

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^live_socket_id}
    end

    test "works even if user is already logged out", %{conn: conn} do
      conn = UserAuth.log_out_user(conn)
      refute get_session(conn, :workos_session_id)
      assert redirected_to(conn) == ~p"/"
    end

    test "redirects to WorkOS session logout when a WorkOS session id exists", %{conn: conn} do
      return_to = FizzWeb.Endpoint.url() <> "/"

      expected_logout_url =
        "https://api.workos.com/user_management/sessions/logout?" <>
          URI.encode_query(%{session_id: "session_workos_123", return_to: return_to})

      conn =
        conn
        |> put_session(:workos_session_id, "session_workos_123")
        |> put_session(:live_socket_id, "workos_sessions:dummy")
        |> UserAuth.log_out_user()

      assert redirected_to(conn) == expected_logout_url
      refute get_session(conn, :workos_session_id)
      refute get_session(conn, :live_socket_id)
    end
  end

  describe "fetch_current_scope_for_user/2" do
    test "authenticates user from WorkOS session", %{conn: conn, user: user} do
      conn =
        conn
        |> put_workos_session(user)
        |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user.id == user.id
      assert conn.assigns.current_scope.user.authenticated_at == nil
      assert get_session(conn, :workos_user_id) == user.workos_user_id
    end

    test "does not authenticate if session data is missing", %{conn: conn} do
      conn = UserAuth.fetch_current_scope_for_user(conn, [])
      assert conn.assigns.current_scope == nil
    end

    test "invalidates session when workos user is unknown", %{conn: conn, user: user} do
      conn =
        conn
        |> put_workos_session(user, %{workos_user_id: "user_missing"})
        |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope == nil
      refute get_session(conn, :workos_user_id)
      refute get_session(conn, :workos_session_id)
      refute get_session(conn, :live_socket_id)
    end
  end

  describe "on_mount :mount_current_scope" do
    setup %{conn: conn} do
      %{conn: UserAuth.fetch_current_scope_for_user(conn, [])}
    end

    test "assigns current_scope based on a valid workos_user_id", %{conn: conn, user: user} do
      session = conn |> put_session(:workos_user_id, user.workos_user_id) |> get_session()

      {:cont, updated_socket} =
        UserAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope.user.id == user.id
    end

    test "assigns nil to current_scope assign if there is no matching user", %{conn: conn} do
      session = conn |> put_session(:workos_user_id, "missing_user") |> get_session()

      {:cont, updated_socket} =
        UserAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope == nil
    end

    test "assigns nil to current_scope assign if there is no workos_user_id", %{conn: conn} do
      session = get_session(conn)

      {:cont, updated_socket} =
        UserAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope == nil
    end
  end

  describe "on_mount :require_authenticated" do
    test "authenticates current_scope based on a valid workos_user_id", %{conn: conn, user: user} do
      session = conn |> put_session(:workos_user_id, user.workos_user_id) |> get_session()

      {:cont, updated_socket} =
        UserAuth.on_mount(:require_authenticated, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope.user.id == user.id
    end

    test "redirects to login page if there is no matching local user", %{conn: conn} do
      session = conn |> put_session(:workos_user_id, "missing_user") |> get_session()

      socket = %LiveView.Socket{
        endpoint: FizzWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} = UserAuth.on_mount(:require_authenticated, %{}, session, socket)
      assert updated_socket.assigns.current_scope == nil
    end

    test "redirects to login page if there is no workos_user_id", %{conn: conn} do
      session = get_session(conn)

      socket = %LiveView.Socket{
        endpoint: FizzWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} = UserAuth.on_mount(:require_authenticated, %{}, session, socket)
      assert updated_socket.assigns.current_scope == nil
    end
  end

  describe "require_authenticated_user/2" do
    setup %{conn: conn} do
      %{conn: UserAuth.fetch_current_scope_for_user(conn, [])}
    end

    test "redirects if user is not authenticated", %{conn: conn} do
      conn = conn |> fetch_flash() |> UserAuth.require_authenticated_user([])
      assert conn.halted

      assert redirected_to(conn) == ~p"/auth/workos"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must log in to access this page."
    end

    test "stores the path to redirect to on GET", %{conn: conn} do
      halted_conn =
        %{conn | path_info: ["foo"], query_string: ""}
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert halted_conn.halted
      assert get_session(halted_conn, :user_return_to) == "/foo"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar=baz"}
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert halted_conn.halted
      assert get_session(halted_conn, :user_return_to) == "/foo?bar=baz"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar", method: "POST"}
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert halted_conn.halted
      refute get_session(halted_conn, :user_return_to)
    end

    test "does not redirect if user is authenticated", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> UserAuth.require_authenticated_user([])

      refute conn.halted
      refute conn.status
    end
  end

  describe "disconnect_workos_sessions/1" do
    test "broadcasts disconnect messages for each session id" do
      session_ids = ["session_1", "session_2"]
      topic_1 = "workos_sessions:#{Base.url_encode64("session_1", padding: false)}"
      topic_2 = "workos_sessions:#{Base.url_encode64("session_2", padding: false)}"

      for session_id <- session_ids do
        FizzWeb.Endpoint.subscribe(
          "workos_sessions:#{Base.url_encode64(session_id, padding: false)}"
        )
      end

      UserAuth.disconnect_workos_sessions(session_ids)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: ^topic_1
      }

      assert_receive %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: ^topic_2
      }
    end
  end

  defp put_workos_session(conn, user, overrides \\ %{}) do
    session = workos_session(user, overrides)

    conn
    |> put_session(:workos_access_token, session.access_token)
    |> put_session(:workos_refresh_token, session.refresh_token)
    |> put_session(:workos_session_id, session.session_id)
    |> put_session(:workos_user_id, session.workos_user_id)
    |> put_session(:workos_access_token_expires_at, session.access_token_expires_at)
    |> put_session(
      :live_socket_id,
      "workos_sessions:#{Base.url_encode64(session.session_id, padding: false)}"
    )
  end

  defp workos_session(user, overrides \\ %{}) do
    workos_user_id = Map.get(overrides, :workos_user_id, user.workos_user_id || "user_#{user.id}")
    session_id = Map.get(overrides, :session_id, "session_#{user.id}")
    expires_at = Map.get(overrides, :access_token_expires_at, System.os_time(:second) + 3600)

    claims = %{
      "sub" => workos_user_id,
      "sid" => session_id,
      "exp" => expires_at
    }

    header = Base.url_encode64(~s({"alg":"none","typ":"JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)

    %{
      access_token: "#{header}.#{payload}.",
      refresh_token: "refresh_#{user.id}",
      session_id: session_id,
      workos_user_id: workos_user_id,
      access_token_expires_at: expires_at
    }
  end
end
