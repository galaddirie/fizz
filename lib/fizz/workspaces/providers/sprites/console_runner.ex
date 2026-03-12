defmodule Fizz.Workspaces.Providers.Sprites.ConsoleRunner do
  @moduledoc """
  Bridges a Sprite TTY session and a Phoenix channel process.
  """

  use GenServer

  require Logger

  alias Fizz.Workspaces.Providers.Sprites.Client

  @type option ::
          {:console_id, String.t()}
          | {:remote_name, String.t()}
          | {:channel_pid, pid()}
          | {:rows, integer()}
          | {:cols, integer()}
          | {:env, [{String.t(), String.t()}]}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    console_id = Keyword.fetch!(opts, :console_id)
    remote_name = Keyword.fetch!(opts, :remote_name)
    channel_pid = Keyword.fetch!(opts, :channel_pid)
    rows = Keyword.get(opts, :rows, 24)
    cols = Keyword.get(opts, :cols, 80)
    env = Keyword.get(opts, :env, [])

    Process.monitor(channel_pid)

    with {:ok, remote_workspace} <- Client.workspace(remote_name),
         {:ok, command} <-
           Sprites.spawn(remote_workspace, "bash", ["-i"],
             tty: true,
             stdin: true,
             tty_rows: rows,
             tty_cols: cols,
             env: env,
             owner: self()
           ) do
      {:ok,
       %{
         console_id: console_id,
         channel_pid: channel_pid,
         command: command,
         ref: command.ref,
         rows: rows,
         cols: cols
       }}
    else
      {:error, reason} ->
        Logger.error("workspace console start failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:stdin, data}, state) do
    _ = Sprites.write(state.command, data)
    {:noreply, state}
  end

  def handle_cast({:resize, rows, cols}, state) do
    _ = Sprites.resize(state.command, rows, cols)
    {:noreply, %{state | rows: rows, cols: cols}}
  end

  def handle_cast(:close, state) do
    stop_command(state.command)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:stdout, %{ref: ref}, data}, %{ref: ref} = state) do
    send(state.channel_pid, {:workspace_console_stdout, state.console_id, data})
    {:noreply, state}
  end

  def handle_info({:stderr, %{ref: ref}, data}, %{ref: ref} = state) do
    send(state.channel_pid, {:workspace_console_stderr, state.console_id, data})
    {:noreply, state}
  end

  def handle_info({:exit, %{ref: ref}, exit_code}, %{ref: ref} = state) do
    send(state.channel_pid, {:workspace_console_exit, state.console_id, exit_code})
    {:stop, :normal, state}
  end

  def handle_info({:error, %{ref: ref}, reason}, %{ref: ref} = state) do
    send(state.channel_pid, {:workspace_console_error, state.console_id, inspect(reason)})
    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, _monitor_ref, :process, channel_pid, _reason},
        %{channel_pid: channel_pid} = state
      ) do
    # Sleep-first behavior: channel disconnect tears down the console immediately.
    stop_command(state.command)
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_command(state.command)
    :ok
  end

  defp stop_command(%{pid: pid}) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  rescue
    _ -> :ok
  end

  defp stop_command(_command), do: :ok
end
