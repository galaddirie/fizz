defmodule Fizz.Sprites.Console.SessionServer do
  @moduledoc """
  Runtime process for a single interactive sprite console session.
  """

  use GenServer

  alias Fizz.Sprites.Console.Registry, as: ConsoleRegistry

  @max_buffer_chunks 200

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: ConsoleRegistry.via(session_id))
  end

  @spec subscribe(String.t(), String.t(), pid()) :: {:ok, [map()]} | {:error, term()}
  def subscribe(session_id, user_id, subscriber_pid \\ self())
      when is_binary(session_id) and is_binary(user_id) and is_pid(subscriber_pid) do
    GenServer.call(ConsoleRegistry.via(session_id), {:subscribe, user_id, subscriber_pid})
  end

  @spec detach(String.t(), String.t(), pid()) :: :ok | {:error, term()}
  def detach(session_id, user_id, subscriber_pid \\ self())
      when is_binary(session_id) and is_binary(user_id) and is_pid(subscriber_pid) do
    GenServer.call(ConsoleRegistry.via(session_id), {:detach, user_id, subscriber_pid})
  end

  @spec send_input(String.t(), String.t(), iodata()) :: :ok | {:error, term()}
  def send_input(session_id, user_id, data)
      when is_binary(session_id) and is_binary(user_id) do
    GenServer.call(ConsoleRegistry.via(session_id), {:input, user_id, data})
  end

  @spec resize(String.t(), String.t(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  def resize(session_id, user_id, rows, cols)
      when is_binary(session_id) and is_binary(user_id) and is_integer(rows) and is_integer(cols) do
    GenServer.call(ConsoleRegistry.via(session_id), {:resize, user_id, rows, cols})
  end

  @spec close(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def close(session_id, user_id, reason \\ "closed_by_user")
      when is_binary(session_id) and is_binary(user_id) and is_binary(reason) do
    GenServer.call(ConsoleRegistry.via(session_id), {:close, user_id, reason})
  end

  @spec snapshot(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def snapshot(session_id, user_id) when is_binary(session_id) and is_binary(user_id) do
    GenServer.call(ConsoleRegistry.via(session_id), {:snapshot, user_id})
  end

  @impl true
  def init(opts) do
    provider_module = Keyword.fetch!(opts, :provider_module)
    sprite_name = Keyword.fetch!(opts, :sprite_name)
    session_id = Keyword.fetch!(opts, :session_id)
    owner_user_id = Keyword.fetch!(opts, :owner_user_id)
    mode = Keyword.get(opts, :mode, :start)
    tty = Keyword.get(opts, :tty, true)
    idle_timeout_seconds = Keyword.get(opts, :idle_timeout_seconds)

    state = %{
      provider_module: provider_module,
      sprite_name: sprite_name,
      session_id: session_id,
      owner_user_id: owner_user_id,
      mode: mode,
      tty: tty,
      idle_timeout_seconds: idle_timeout_seconds,
      timeout_ref: nil,
      command_handle: nil,
      command_ref: nil,
      interactive_command: Keyword.get(opts, :command),
      provider_session_id: Keyword.get(opts, :provider_session_id),
      subscriber_pid: nil,
      subscriber_monitor_ref: nil,
      output_buffer: [],
      closed_reason: nil
    }

    with {:ok, command_handle} <- start_provider_console(state, opts),
         {:ok, command_ref} <- command_ref(command_handle) do
      provider_session_id = read_provider_session_id(command_handle, state.provider_session_id)
      register_provider_session_alias(provider_session_id, session_id)

      {:ok,
       state
       |> Map.put(:command_handle, command_handle)
       |> Map.put(:command_ref, command_ref)
       |> Map.put(:provider_session_id, provider_session_id)
       |> reset_idle_timer()}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:subscribe, user_id, subscriber_pid}, _from, state) do
    with :ok <- authorize_owner(state, user_id) do
      state = replace_subscriber(state, subscriber_pid)
      {:reply, {:ok, Enum.reverse(state.output_buffer)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:detach, user_id, subscriber_pid}, _from, state) do
    with :ok <- authorize_owner(state, user_id) do
      if state.subscriber_pid == subscriber_pid do
        {:reply, :ok, clear_subscriber(state)}
      else
        {:reply, :ok, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:input, user_id, data}, _from, state) do
    with :ok <- authorize_owner(state, user_id),
         :ok <- state.provider_module.write_console(state.command_handle, data) do
      {:reply, :ok, reset_idle_timer(state)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resize, user_id, rows, cols}, _from, state) do
    with :ok <- authorize_owner(state, user_id),
         :ok <- state.provider_module.resize_console(state.command_handle, rows, cols) do
      {:reply, :ok, reset_idle_timer(state)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close, user_id, reason}, _from, state) do
    with :ok <- authorize_owner(state, user_id) do
      _ = state.provider_module.close_console(state.command_handle)
      maybe_notify_subscriber(state, {:console_exit, public_session_id(state), nil, reason})
      {:stop, :normal, :ok, %{state | closed_reason: reason}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:snapshot, user_id}, _from, state) do
    with :ok <- authorize_owner(state, user_id) do
      {:reply,
       {:ok,
        %{
          id: public_session_id(state),
          provider_session_id: state.provider_session_id,
          command: state.interactive_command || "",
          tty: state.tty,
          idle_timeout_seconds: state.idle_timeout_seconds
        }}, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state)
      when state.subscriber_monitor_ref == monitor_ref do
    {:noreply, clear_subscriber(state)}
  end

  def handle_info({:stdout, %{ref: ref}, data}, %{command_ref: ref} = state) do
    state =
      state
      |> append_chunk(%{stream: "stdout", data: data})
      |> reset_idle_timer()

    maybe_notify_subscriber(
      state,
      {:console_output, public_session_id(state), %{stream: "stdout", data: data}}
    )

    {:noreply, state}
  end

  def handle_info({:stderr, %{ref: ref}, data}, %{command_ref: ref} = state) do
    state =
      state
      |> append_chunk(%{stream: "stderr", data: data})
      |> reset_idle_timer()

    maybe_notify_subscriber(
      state,
      {:console_output, public_session_id(state), %{stream: "stderr", data: data}}
    )

    {:noreply, state}
  end

  def handle_info({:exit, %{ref: ref}, exit_code}, %{command_ref: ref} = state) do
    maybe_notify_subscriber(
      state,
      {:console_exit, public_session_id(state), exit_code, "command_exit"}
    )

    {:stop, :normal, state}
  end

  def handle_info({:error, %{ref: ref}, reason}, %{command_ref: ref} = state) do
    maybe_notify_subscriber(
      state,
      {:console_exit, public_session_id(state), nil, inspect(reason)}
    )

    {:stop, :normal, state}
  end

  def handle_info(:idle_timeout, state) do
    _ = state.provider_module.close_console(state.command_handle)
    maybe_notify_subscriber(state, {:console_exit, public_session_id(state), nil, "idle_timeout"})
    {:stop, :normal, %{state | closed_reason: "idle_timeout"}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    clear_subscriber(state)
    :ok
  end

  defp start_provider_console(state, opts) do
    case state.mode do
      :start ->
        command = Keyword.get(opts, :command, "bash")
        args = Keyword.get(opts, :args, [])

        state.provider_module.start_console(
          state.sprite_name,
          command,
          args,
          tty: state.tty,
          owner: self()
        )

      :attach ->
        provider_session_id = Keyword.fetch!(opts, :provider_session_id)

        state.provider_module.attach_console(
          state.sprite_name,
          provider_session_id,
          tty: state.tty,
          owner: self()
        )
    end
  end

  defp command_ref(command_handle) do
    case command_handle do
      %{ref: ref} when is_reference(ref) -> {:ok, ref}
      _ -> {:error, :missing_command_ref}
    end
  end

  defp read_provider_session_id(command_handle, fallback) do
    case command_handle do
      %{provider_session_id: provider_session_id} when is_binary(provider_session_id) ->
        provider_session_id

      %{"provider_session_id" => provider_session_id} when is_binary(provider_session_id) ->
        provider_session_id

      _ ->
        fallback
    end
  end

  defp register_provider_session_alias(provider_session_id, session_id) do
    if is_binary(provider_session_id) and provider_session_id != "" and
         provider_session_id != session_id do
      _ =
        Elixir.Registry.register(
          Fizz.Sprites.Console.Registry,
          provider_session_id,
          :provider_alias
        )
    end

    :ok
  end

  defp public_session_id(state) do
    if is_binary(state.provider_session_id) and state.provider_session_id != "" do
      state.provider_session_id
    else
      state.session_id
    end
  end

  defp authorize_owner(%{owner_user_id: owner_user_id}, owner_user_id), do: :ok
  defp authorize_owner(_state, _user_id), do: {:error, :forbidden}

  defp replace_subscriber(state, subscriber_pid) do
    state = clear_subscriber(state)
    monitor_ref = Process.monitor(subscriber_pid)
    %{state | subscriber_pid: subscriber_pid, subscriber_monitor_ref: monitor_ref}
  end

  defp clear_subscriber(state) do
    if is_reference(state.subscriber_monitor_ref) do
      Process.demonitor(state.subscriber_monitor_ref, [:flush])
    end

    %{state | subscriber_pid: nil, subscriber_monitor_ref: nil}
  end

  defp maybe_notify_subscriber(state, message) do
    if is_pid(state.subscriber_pid) do
      send(state.subscriber_pid, message)
    end

    :ok
  end

  defp append_chunk(state, chunk) do
    output_buffer =
      [chunk | state.output_buffer]
      |> Enum.take(@max_buffer_chunks)

    %{state | output_buffer: output_buffer}
  end

  defp reset_idle_timer(state) do
    if is_reference(state.timeout_ref) do
      Process.cancel_timer(state.timeout_ref, async: true, info: false)
    end

    timeout_ref =
      case state.idle_timeout_seconds do
        nil ->
          nil

        seconds when is_integer(seconds) and seconds > 0 ->
          Process.send_after(self(), :idle_timeout, seconds * 1000)

        _ ->
          nil
      end

    %{state | timeout_ref: timeout_ref}
  end
end
