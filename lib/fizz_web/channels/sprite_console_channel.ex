defmodule FizzWeb.SpriteConsoleChannel do
  use FizzWeb, :channel

  alias Fizz.Integrations
  alias Fizz.Sprites
  alias Fizz.Sprites.{ConsoleRunner, GitCredentialSetup}

  require Logger

  @impl true
  def join("sprite_console:" <> console_id, _payload, socket) do
    scope = socket.assigns.current_scope

    with {:ok, console_session} <- Sprites.authorize_console_session(scope, console_id),
         :active <- console_session.state,
         env_tuples = setup_git_credentials(scope, console_session),
         {:ok, runner_pid} <-
           ConsoleRunner.start_link(
             console_id: console_session.id,
             remote_name: console_session.sprite.remote_name,
             channel_pid: self(),
             rows: console_session.rows,
             cols: console_session.cols,
             env: env_tuples
           ) do
      Process.monitor(runner_pid)

      socket =
        socket
        |> assign(:console_id, console_session.id)
        |> assign(:sprite_id, console_session.sprite_id)
        |> assign(:workspace_id, console_session.workspace_id)
        |> assign(:runner_pid, runner_pid)
        |> assign(:console_closed?, false)

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
    socket = maybe_close_console(socket, "closed")
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
    socket = maybe_close_console(socket, "exit")
    {:stop, :normal, socket}
  end

  def handle_info(
        {:sprite_console_error, console_id, reason},
        %{assigns: %{console_id: console_id}} = socket
      ) do
    push(socket, "error", %{reason: reason})
    Sprites.flag_console_error(console_id, reason)
    {:stop, :normal, assign(socket, :console_closed?, true)}
  end

  def handle_info(
        {:DOWN, _ref, :process, runner_pid, _reason},
        %{assigns: %{runner_pid: runner_pid}} = socket
      ) do
    push(socket, "closed", %{reason: "runner_down"})
    socket = maybe_close_console(socket, "runner_down")
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

    _socket = maybe_close_console(socket, close_reason)
    :ok
  end

  defp maybe_close_console(%{assigns: %{console_closed?: true}} = socket, _reason), do: socket

  defp maybe_close_console(%{assigns: assigns} = socket, reason) do
    if assigns[:console_id] && assigns[:workspace_id] && assigns[:sprite_id] do
      _ =
        Sprites.close_console(
          socket.assigns.current_scope,
          assigns.workspace_id,
          assigns.sprite_id,
          assigns.console_id,
          reason
        )
    end

    assign(socket, :console_closed?, true)
  end

  defp normalize_integer(value, _fallback) when is_integer(value), do: value

  defp normalize_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> fallback
    end
  end

  defp normalize_integer(_value, fallback), do: fallback

  defp setup_git_credentials(scope, console_session) do
    workspace_id = console_session.workspace_id
    remote_name = console_session.sprite.remote_name

    with {:ok, token_result} <-
           Integrations.fetch_token_for_sprite(scope, workspace_id, "github_oauth") do
      user_opts = git_user_opts(scope, workspace_id)

      case GitCredentialSetup.setup(remote_name, token_result.access_token, user_opts) do
        {:ok, env_tuples} ->
          env_tuples

        {:error, reason} ->
          Logger.warning("Git credential setup failed: #{inspect(reason)}")
          []
      end
    else
      {:error, reason} ->
        Logger.debug("Git credential setup skipped: #{inspect(reason)}")
        []
    end
  end

  defp git_user_opts(scope, workspace_id) do
    case Integrations.get_connection(scope, workspace_id, "github_oauth") do
      {:ok, connection} ->
        meta = connection.provider_metadata || %{}
        name = meta["name"] || meta["username"]
        email = meta["email"] || github_noreply_email(meta["username"])

        [user_name: name, user_email: email]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      {:error, _} ->
        []
    end
  end

  defp github_noreply_email(nil), do: nil
  defp github_noreply_email(username), do: "#{username}@users.noreply.github.com"
end
