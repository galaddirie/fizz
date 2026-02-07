defmodule FizzWeb.WorkOSAuthController do
  use FizzWeb, :controller

  alias Fizz.Accounts
  alias FizzWeb.UserAuth

  @state_session_key :workos_auth_state

  def authorize(conn, _params) do
    state = generate_state()

    auth_params = %{
      redirect_uri: redirect_uri(conn),
      provider: authkit_provider(),
      state: state
    }

    conn = put_session(conn, @state_session_key, state)

    case Accounts.workos_authorization_url(auth_params) do
      {:ok, authorization_url} ->
        redirect(conn, external: authorization_url)

      {:error, reason} ->
        conn
        |> delete_session(@state_session_key)
        |> put_flash(
          :error,
          "WorkOS authentication is not available right now. (reason: #{inspect(reason)})"
        )
        |> redirect(to: ~p"/")
    end
  end

  def callback(conn, %{"code" => code} = params) do
    expected_state = get_session(conn, @state_session_key)
    conn = delete_session(conn, @state_session_key)

    with :ok <- verify_state(expected_state, params["state"]),
         {:ok, %{user: user, workos_session_id: workos_session_id}} <-
           Accounts.authenticate_user_with_workos_code_and_session(code,
             ip_address: client_ip(conn),
             user_agent: List.first(get_req_header(conn, "user-agent"))
           ) do
      conn
      |> put_flash(:info, "Welcome back!")
      |> UserAuth.log_in_user(user, %{workos_session_id: workos_session_id})
    else
      {:error, reason} ->
        conn
        |> put_flash(:error, callback_error_message(reason))
        |> redirect(to: ~p"/")
    end
  end

  def callback(conn, _params) do
    conn
    |> delete_session(@state_session_key)
    |> put_flash(:error, "The WorkOS callback is missing required parameters.")
    |> redirect(to: ~p"/")
  end

  defp verify_state(expected_state, incoming_state)
       when is_binary(expected_state) and is_binary(incoming_state) do
    if byte_size(expected_state) == byte_size(incoming_state) and
         Plug.Crypto.secure_compare(expected_state, incoming_state) do
      :ok
    else
      {:error, :invalid_state}
    end
  end

  defp verify_state(_, _), do: {:error, :invalid_state}

  defp callback_error_message(:invalid_state), do: "Your login session expired. Please try again."

  defp callback_error_message(:workos_account_conflict) do
    "An account conflict was detected for this WorkOS identity. Contact support."
  end

  defp callback_error_message(_), do: "Could not authenticate with WorkOS. Please try again."

  defp generate_state do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp redirect_uri(_conn) do
    Application.get_env(:fizz, :workos_authkit_redirect_uri) ||
      FizzWeb.Endpoint.url() <> ~p"/auth/workos/callback"
  end

  defp authkit_provider do
    Application.get_env(:fizz, :workos_authkit_provider, "authkit")
  end

  defp client_ip(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end
end
