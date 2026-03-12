defmodule FizzWeb.UserSocket do
  use Phoenix.Socket

  alias Fizz.Accounts
  alias Fizz.Accounts.Scope

  channel "workspace_console:*", FizzWeb.WorkspaceConsoleChannel
  channel "workspace_logs:*", FizzWeb.WorkspaceLogsChannel

  @impl true
  def connect(_params, socket, %{session: session}) do
    with workos_user_id when is_binary(workos_user_id) and byte_size(workos_user_id) > 0 <-
           session["workos_user_id"],
         workos_session_id
         when is_binary(workos_session_id) and byte_size(workos_session_id) > 0 <-
           session["workos_session_id"],
         %{} = user <- Accounts.get_user_by_workos_user_id(workos_user_id) do
      {:ok,
       socket
       |> assign(:current_scope, Scope.for_user(user))
       |> assign(:workos_session_topic, workos_session_topic(workos_session_id))}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: socket.assigns[:workos_session_topic]

  defp workos_session_topic(session_id),
    do: "workos_sessions:#{Base.url_encode64(session_id, padding: false)}"
end
