defmodule FizzWeb.UserAuth do
  use FizzWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Fizz.Accounts
  alias Fizz.Accounts.Scope

  # Make the remember me cookie valid for 14 days. This should match
  # the session validity setting in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_fizz_web_user_remember_me"
  @workos_session_id :workos_session_id
  @workos_access_token :workos_access_token
  @workos_refresh_token :workos_refresh_token
  @workos_user_id :workos_user_id
  @workos_access_token_expires_at :workos_access_token_expires_at
  @workos_access_token_expiry_leeway_seconds 30
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # How old the session token should be before a new one is issued. When a request is made
  # with a session token older than this value, then a new session token will be created
  # and the session and remember-me cookies (if set) will be updated with the new token.
  # Lowering this value will result in more tokens being created by active users. Increasing
  # it will result in less time before a session token expires for a user to get issued a new
  # token. This can be set to a value greater than `@max_cookie_age_in_days` to disable
  # the reissuing of tokens completely.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in.

  Redirects to the session's `:user_return_to` path
  or falls back to the `signed_in_path/1`.
  """
  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    workos_session_id = get_session(conn, @workos_session_id)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      FizzWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn =
      conn
      |> renew_session(nil)
      |> delete_resp_cookie(@remember_me_cookie)

    case workos_logout_url(workos_session_id, post_logout_return_to()) do
      {:ok, logout_url} -> redirect(conn, external: logout_url)
      :error -> redirect(conn, to: ~p"/")
    end
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at} <- Accounts.get_user_by_session_token(token),
         {:ok, conn, user} <- ensure_workos_session(conn, user) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> maybe_reissue_user_session_token(user, token_inserted_at)
    else
      {:error, conn} -> assign(conn, :current_scope, Scope.for_user(nil))
      nil -> assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  defp ensure_workos_session(conn, %{workos_user_id: workos_user_id} = user)
       when is_binary(workos_user_id) and byte_size(workos_user_id) > 0 do
    with {:ok, workos_session} <- read_workos_session(conn),
         :ok <- ensure_workos_user_match(workos_user_id, workos_session.workos_user_id) do
      if access_token_expired?(workos_session.access_token_expires_at) do
        refresh_workos_session(conn, user, workos_session)
      else
        {:ok, conn, user}
      end
    else
      _ ->
        {:error, invalidate_local_session(conn)}
    end
  end

  defp ensure_workos_session(conn, user), do: {:ok, clear_workos_session(conn), user}

  defp refresh_workos_session(conn, user, workos_session) do
    case Accounts.refresh_user_workos_session(workos_session.refresh_token,
           ip_address: client_ip(conn),
           user_agent: List.first(get_req_header(conn, "user-agent"))
         ) do
      {:ok, %{user: refreshed_user, workos_session: refreshed_session}} ->
        with :ok <- ensure_same_local_user(user, refreshed_user),
             :ok <-
               ensure_workos_user_match(user.workos_user_id, refreshed_session.workos_user_id) do
          {:ok, put_workos_session(conn, refreshed_session), refreshed_user}
        else
          _ -> {:error, invalidate_local_session(conn)}
        end

      _ ->
        {:error, invalidate_local_session(conn)}
    end
  end

  defp ensure_same_local_user(%{id: id}, %{id: id}), do: :ok
  defp ensure_same_local_user(_user, _refreshed_user), do: {:error, :local_user_mismatch}

  defp ensure_workos_user_match(workos_user_id, workos_user_id), do: :ok
  defp ensure_workos_user_match(_expected, _actual), do: {:error, :workos_user_mismatch}

  defp access_token_expired?(expires_at) when is_integer(expires_at) do
    expires_at <= System.os_time(:second) + @workos_access_token_expiry_leeway_seconds
  end

  defp access_token_expired?(_), do: true

  # This function is the one responsible for creating session tokens
  # and storing them safely in the session and cookies. It may be called
  # either when logging in, during sudo mode, or to renew a session which
  # will soon expire.
  #
  # When the session is created, rather than extended, the renew_session
  # function will clear the session to avoid fixation attacks. See the
  # renew_session function to customize this behaviour.
  defp create_or_extend_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_put_workos_session(params)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew session if the user is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn, _user) do
  #       delete_csrf_token()
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(conn, _user) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp maybe_put_workos_session(conn, params) when is_list(params) do
    maybe_put_workos_session(conn, Map.new(params))
  end

  defp maybe_put_workos_session(conn, params) when is_map(params) do
    cond do
      Map.has_key?(params, :workos_session) ->
        maybe_put_workos_session_from_value(conn, params[:workos_session], true)

      Map.has_key?(params, "workos_session") ->
        maybe_put_workos_session_from_value(conn, params["workos_session"], true)

      Map.has_key?(params, :workos_session_id) ->
        put_session(conn, @workos_session_id, params[:workos_session_id])

      Map.has_key?(params, "workos_session_id") ->
        put_session(conn, @workos_session_id, params["workos_session_id"])

      true ->
        conn
    end
  end

  defp maybe_put_workos_session(conn, _params), do: conn

  defp maybe_put_workos_session_from_value(conn, %{} = workos_session, true) do
    access_token = read_value(workos_session, [:access_token, "access_token"])
    refresh_token = read_value(workos_session, [:refresh_token, "refresh_token"])
    session_id = read_value(workos_session, [:session_id, "session_id"])
    workos_user_id = read_value(workos_session, [:workos_user_id, "workos_user_id"])

    expires_at =
      workos_session
      |> read_value([:access_token_expires_at, "access_token_expires_at"])
      |> normalize_integer()

    conn
    |> maybe_put_session(@workos_access_token, access_token)
    |> maybe_put_session(@workos_refresh_token, refresh_token)
    |> maybe_put_session(@workos_session_id, session_id)
    |> maybe_put_session(@workos_user_id, workos_user_id)
    |> maybe_put_session(@workos_access_token_expires_at, expires_at)
  end

  defp maybe_put_workos_session_from_value(conn, nil, true), do: clear_workos_session(conn)
  defp maybe_put_workos_session_from_value(conn, _workos_session, _present?), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp read_workos_session(conn) do
    access_token = get_session(conn, @workos_access_token)
    refresh_token = get_session(conn, @workos_refresh_token)
    session_id = get_session(conn, @workos_session_id)
    workos_user_id = get_session(conn, @workos_user_id)
    expires_at = normalize_integer(get_session(conn, @workos_access_token_expires_at))

    if is_binary(access_token) and is_binary(refresh_token) and is_binary(session_id) and
         is_binary(workos_user_id) and is_integer(expires_at) do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: refresh_token,
         session_id: session_id,
         workos_user_id: workos_user_id,
         access_token_expires_at: expires_at
       }}
    else
      {:error, :missing_workos_session}
    end
  end

  defp put_workos_session(conn, %{} = workos_session) do
    conn
    |> maybe_put_session(
      @workos_access_token,
      read_value(workos_session, [:access_token, "access_token"])
    )
    |> maybe_put_session(
      @workos_refresh_token,
      read_value(workos_session, [:refresh_token, "refresh_token"])
    )
    |> maybe_put_session(
      @workos_session_id,
      read_value(workos_session, [:session_id, "session_id"])
    )
    |> maybe_put_session(
      @workos_user_id,
      read_value(workos_session, [:workos_user_id, "workos_user_id"])
    )
    |> maybe_put_session(
      @workos_access_token_expires_at,
      workos_session
      |> read_value([:access_token_expires_at, "access_token_expires_at"])
      |> normalize_integer()
    )
  end

  defp clear_workos_session(conn) do
    conn
    |> delete_session(@workos_access_token)
    |> delete_session(@workos_refresh_token)
    |> delete_session(@workos_session_id)
    |> delete_session(@workos_user_id)
    |> delete_session(@workos_access_token_expires_at)
  end

  defp invalidate_local_session(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie)
  end

  defp maybe_put_session(conn, key, value) when is_binary(value) and byte_size(value) > 0 do
    put_session(conn, key, value)
  end

  defp maybe_put_session(conn, key, value) when is_integer(value),
    do: put_session(conn, key, value)

  defp maybe_put_session(conn, key, _value), do: delete_session(conn, key)

  defp read_value(data, keys) do
    Enum.find_value(keys, fn key ->
      case data do
        %{} -> Map.get(data, key)
        _ -> nil
      end
    end)
  end

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp post_logout_return_to do
    Application.get_env(:fizz, :workos_authkit_logout_return_uri) ||
      FizzWeb.Endpoint.url() <> ~p"/"
  end

  defp workos_logout_url(session_id, return_to)
       when is_binary(session_id) and byte_size(session_id) > 0 and is_binary(return_to) do
    base_url = String.trim_trailing(WorkOS.base_url(), "/")
    query = URI.encode_query(%{session_id: session_id, return_to: return_to})
    {:ok, "#{base_url}/user_management/sessions/logout?#{query}"}
  end

  defp workos_logout_url(_, _), do: :error

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      FizzWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule FizzWeb.PageLive do
        use FizzWeb, :live_view

        on_mount {FizzWeb.UserAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{FizzWeb.UserAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/auth/workos")

      {:halt, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      {user, _} =
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end || {nil, nil}

      Scope.for_user(user)
    end)
  end

  @doc "Returns the path to redirect to after log in."
  def signed_in_path(_), do: ~p"/"

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/auth/workos")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp client_ip(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end
end
