defmodule FizzWeb.SpriteConsoleChannel do
  use FizzWeb, :channel

  alias Fizz.Sprites
  alias Fizz.Sprites.ConsoleRunner

  require Logger

  @impl true
  def join("sprite_console:" <> console_id, _payload, socket) do
    scope = socket.assigns.current_scope

    with {:ok, console_session} <- Sprites.authorize_console_session(scope, console_id),
         :active <- console_session.state,
         {:ok, runner_pid} <-
           ConsoleRunner.start_link(
             console_id: console_session.id,
             remote_name: console_session.sprite.remote_name,
             channel_pid: self(),
             rows: console_session.rows,
             cols: console_session.cols,
             env: []
           ) do
      Process.monitor(runner_pid)

      socket =
        socket
        |> assign(:console_id, console_session.id)
        |> assign(:sprite_id, console_session.sprite_id)
        |> assign(:workspace_id, console_session.workspace_id)
        |> assign(:runner_pid, runner_pid)

      {:ok, %{console_id: console_session.id}, socket}
    else
      :closed -> {:error, %{reason: "console_closed"}}
      :errored -> {:error, %{reason: "console_errored"}}
      {:error, reason} -> {:error, %{reason: to_string(reason)}}
    end
  end

  @impl true
  def handle_in("stdin", %{"data" => data}, socket) do
    if is_binary(data), do: GenServer.cast(socket.assigns.runner_pid, {:stdin, data})
    {:noreply, socket}
  end

  def handle_in("resize", %{"rows" => rows, "cols" => cols}, socket) do
    rows = normalize_integer(rows, 24)
    cols = normalize_integer(cols, 80)

    GenServer.cast(socket.assigns.runner_pid, {:resize, rows, cols})
    {:noreply, socket}
  end

  def handle_in("close", _payload, socket) do
    close_console(socket, "closed")
    {:stop, :normal, socket}
  end

  @impl true
  def handle_info(
        {:sprite_console_stdout, console_id, data},
        %{assigns: %{console_id: console_id}} = socket
      ) do
    push(socket, "stdout", %{data: Base.encode64(data)})
    {:noreply, socket}
  end

  def handle_info(
        {:sprite_console_stderr, console_id, data},
        %{assigns: %{console_id: console_id}} = socket
      ) do
    push(socket, "stderr", %{data: Base.encode64(data)})
    {:noreply, socket}
  end

  def handle_info(
        {:sprite_console_exit, console_id, exit_code},
        %{assigns: %{console_id: console_id}} = socket
      ) do
    push(socket, "exit", %{exit_code: exit_code})
    close_console(socket, "exit")
    {:stop, :normal, socket}
  end

  def handle_info(
        {:sprite_console_error, console_id, reason},
        %{assigns: %{console_id: console_id}} = socket
      ) do
    push(socket, "error", %{reason: reason})
    Sprites.flag_console_error(console_id, reason)
    {:stop, :normal, socket}
  end

  def handle_info(
        {:DOWN, _ref, :process, runner_pid, _reason},
        %{assigns: %{runner_pid: runner_pid}} = socket
      ) do
    push(socket, "closed", %{reason: "runner_down"})
    close_console(socket, "runner_down")
    {:stop, :normal, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(reason, socket) do
    if runner_pid = socket.assigns[:runner_pid] do
      if Process.alive?(runner_pid) do
        GenServer.cast(runner_pid, :close)
      end
    end

    close_reason =
      case reason do
        :normal -> "closed"
        _ -> "disconnect"
      end

    close_console(socket, close_reason)
    :ok
  end

  defp close_console(%{assigns: assigns} = socket, _reason) do
    if assigns[:console_id] && assigns[:workspace_id] && assigns[:sprite_id] do
      _ =
        Sprites.close_console(
          socket.assigns.current_scope,
          assigns.workspace_id,
          assigns.sprite_id,
          assigns.console_id
        )
    end

    :ok
  end

  defp normalize_integer(value, _fallback) when is_integer(value), do: value

  defp normalize_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> fallback
    end
  end

  defp normalize_integer(_value, fallback), do: fallback
end
