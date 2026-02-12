defmodule FizzWeb.UserAuth do
  use FizzWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Fizz.Accounts
  alias Fizz.Accounts.Scope

  @workos_session_id :workos_session_id
  @workos_access_token :workos_access_token
  @workos_refresh_token :workos_refresh_token
  @workos_user_id :workos_user_id
  @workos_access_token_expires_at :workos_access_token_expires_at
  @live_socket_id :live_socket_id
  @workos_access_token_expiry_leeway_seconds 30

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
    workos_session_id = get_session(conn, @workos_session_id)

    if live_socket_id = get_session(conn, @live_socket_id) do
      FizzWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn = renew_session(conn, nil)

    case workos_logout_url(workos_session_id, post_logout_return_to()) do
      {:ok, logout_url} -> redirect(conn, external: logout_url)
      :error -> redirect(conn, to: ~p"/")
    end
  end

  @doc """
  Authenticates the user from the WorkOS session data stored in the Plug session.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    case authenticate_user_from_workos_session(conn) do
      {:ok, conn, user} ->
        assign(conn, :current_scope, Scope.for_user(user))

      {:error, conn} ->
        assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp authenticate_user_from_workos_session(conn) do
    with {:ok, workos_session} <- read_workos_session(conn),
         %{} = user <- Accounts.get_user_by_workos_user_id(workos_session.workos_user_id),
         {:ok, conn, user} <- ensure_workos_session(conn, user, workos_session) do
      {:ok, conn, user}
    else
      _ ->
        {:error, invalidate_local_session(conn)}
    end
  end

  defp ensure_workos_session(conn, %{workos_user_id: workos_user_id} = user, workos_session)
       when is_binary(workos_user_id) and byte_size(workos_user_id) > 0 do
    with :ok <- ensure_workos_user_match(workos_user_id, workos_session.workos_user_id) do
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

  defp ensure_workos_session(conn, _user, _workos_session),
    do: {:error, invalidate_local_session(conn)}

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

  # This function stores WorkOS session state as the only local auth source.
  defp create_or_extend_session(conn, user, params) do
    conn
    |> renew_session(user)
    |> maybe_put_workos_session(params)
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

  defp maybe_put_workos_session(conn, params) when is_list(params) do
    maybe_put_workos_session(conn, Map.new(params))
  end

  defp maybe_put_workos_session(conn, params) when is_map(params) do
    cond do
      Map.has_key?(params, :workos_session) ->
        maybe_put_workos_session_from_value(conn, params[:workos_session], true)

      Map.has_key?(params, "workos_session") ->
        maybe_put_workos_session_from_value(conn, params["workos_session"], true)

      true ->
        conn
    end
  end

  defp maybe_put_workos_session(conn, _params), do: conn

  defp maybe_put_workos_session_from_value(conn, %{} = workos_session, true),
    do: put_workos_session(conn, workos_session)

  defp maybe_put_workos_session_from_value(conn, nil, true), do: clear_workos_session(conn)
  defp maybe_put_workos_session_from_value(conn, _workos_session, _present?), do: conn

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
    session_id = read_value(workos_session, [:session_id, "session_id"])

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
      session_id
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
    |> maybe_put_live_socket_id(session_id)
  end

  defp clear_workos_session(conn) do
    conn
    |> delete_session(@workos_access_token)
    |> delete_session(@workos_refresh_token)
    |> delete_session(@workos_session_id)
    |> delete_session(@workos_user_id)
    |> delete_session(@workos_access_token_expires_at)
    |> delete_session(@live_socket_id)
  end

  defp invalidate_local_session(conn) do
    clear_workos_session(conn)
  end

  defp maybe_put_session(conn, key, value) when is_binary(value) and byte_size(value) > 0 do
    put_session(conn, key, value)
  end

  defp maybe_put_session(conn, key, value) when is_integer(value),
    do: put_session(conn, key, value)

  defp maybe_put_session(conn, key, _value), do: delete_session(conn, key)

  defp maybe_put_live_socket_id(conn, session_id)
       when is_binary(session_id) and byte_size(session_id) > 0 do
    put_session(conn, @live_socket_id, workos_session_topic(session_id))
  end

  defp maybe_put_live_socket_id(conn, _session_id), do: delete_session(conn, @live_socket_id)

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

  @doc """
  Disconnects existing sockets for the given WorkOS session ids.
  """
  def disconnect_workos_sessions(session_ids) do
    Enum.each(session_ids, &disconnect_workos_session/1)
  end

  @doc """
  Disconnects existing sockets for a WorkOS session id.
  """
  def disconnect_workos_session(session_id)
      when is_binary(session_id) and byte_size(session_id) > 0 do
    FizzWeb.Endpoint.broadcast(workos_session_topic(session_id), "disconnect", %{})
  end

  def disconnect_workos_session(_session_id), do: :ok

  defp workos_session_topic(session_id),
    do: "workos_sessions:#{Base.url_encode64(session_id, padding: false)}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on WorkOS session fields, or nil if
      there is no valid WorkOS session.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based
      on WorkOS session fields.
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
        live "/settings/", UserManagementLive, :index
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
      user =
        case session["workos_user_id"] do
          workos_user_id when is_binary(workos_user_id) and byte_size(workos_user_id) > 0 ->
            Accounts.get_user_by_workos_user_id(workos_user_id)

          _ ->
            nil
        end

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
