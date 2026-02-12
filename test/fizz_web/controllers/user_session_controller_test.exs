defmodule FizzWeb.UserSessionControllerTest do
  use FizzWeb.ConnCase, async: true

  import Fizz.AccountsFixtures

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      session_id = get_session(conn, :workos_session_id)
      return_to = FizzWeb.Endpoint.url() <> "/"

      expected_logout_url =
        "https://api.workos.com/user_management/sessions/logout?" <>
          URI.encode_query(%{session_id: session_id, return_to: return_to})

      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == expected_logout_url
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "redirects through WorkOS logout when a WorkOS session id is present", %{conn: conn} do
      user = user_fixture()
      return_to = FizzWeb.Endpoint.url() <> "/"

      expected_logout_url =
        "https://api.workos.com/user_management/sessions/logout?" <>
          URI.encode_query(%{session_id: "session_workos_123", return_to: return_to})

      conn =
        conn
        |> log_in_user(user)
        |> put_session(:workos_session_id, "session_workos_123")
        |> delete(~p"/users/log-out")

      assert redirected_to(conn) == expected_logout_url
      refute get_session(conn, :user_token)
      refute get_session(conn, :workos_session_id)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
