defmodule FizzWeb.UserSocketTest do
  use Fizz.DataCase, async: true

  import Fizz.AccountsFixtures

  alias FizzWeb.UserSocket

  test "connect/3 assigns current scope and uses WorkOS session topic id" do
    user = user_fixture()
    session_id = "session_#{user.id}"
    socket = %Phoenix.Socket{}

    assert {:ok, connected_socket} =
             UserSocket.connect(%{}, socket, %{
               session: %{
                 "workos_user_id" => user.workos_user_id,
                 "workos_session_id" => session_id
               }
             })

    assert connected_socket.assigns.current_scope.user.id == user.id

    assert UserSocket.id(connected_socket) ==
             "workos_sessions:#{Base.url_encode64(session_id, padding: false)}"
  end

  test "connect/3 rejects sessions without a workos session id" do
    user = user_fixture()

    assert :error =
             UserSocket.connect(%{}, %Phoenix.Socket{}, %{
               session: %{"workos_user_id" => user.workos_user_id}
             })
  end
end
