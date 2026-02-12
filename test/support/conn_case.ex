defmodule FizzWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use FizzWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint FizzWeb.Endpoint

      use FizzWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import FizzWeb.ConnCase
    end
  end

  setup tags do
    Fizz.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in users.

      setup :register_and_log_in_user

  It stores an updated connection and a registered user in the
  test context.
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    user = Fizz.AccountsFixtures.user_fixture()
    scope = Fizz.Accounts.Scope.for_user(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  Logs the given `user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = Fizz.Accounts.generate_user_session_token(user)

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])
    workos_session = fake_workos_session_for_user(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:workos_access_token, workos_session.access_token)
    |> Plug.Conn.put_session(:workos_refresh_token, workos_session.refresh_token)
    |> Plug.Conn.put_session(:workos_session_id, workos_session.session_id)
    |> Plug.Conn.put_session(:workos_user_id, workos_session.workos_user_id)
    |> Plug.Conn.put_session(
      :workos_access_token_expires_at,
      workos_session.access_token_expires_at
    )
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    Fizz.AccountsFixtures.override_token_authenticated_at(token, authenticated_at)
  end

  defp fake_workos_session_for_user(user) do
    workos_user_id = user.workos_user_id || "user_#{user.id}"
    session_id = "session_#{user.id}"
    expires_at = System.os_time(:second) + 3600

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
