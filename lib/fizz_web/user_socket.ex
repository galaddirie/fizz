defmodule FizzWeb.UserSocket do
  use Phoenix.Socket

  alias Fizz.Accounts
  alias Fizz.Accounts.Scope

  channel "sprite_console:*", FizzWeb.SpriteConsoleChannel
  channel "sprite_logs:*", FizzWeb.SpriteLogsChannel

  @impl true
  def connect(_params, socket, %{session: session}) do
    case session["workos_user_id"] do
      workos_user_id when is_binary(workos_user_id) and byte_size(workos_user_id) > 0 ->
        case Accounts.get_user_by_workos_user_id(workos_user_id) do
          %{} = user ->
            {:ok, assign(socket, :current_scope, Scope.for_user(user))}

          nil ->
            :error
        end

      _ ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket) do
    case socket.assigns[:current_scope] do
      %Scope{user: %{id: user_id}} when is_binary(user_id) -> "users_socket:#{user_id}"
      _ -> nil
    end
  end
end
