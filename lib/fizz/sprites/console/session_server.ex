defmodule Fizz.Sprites.Console.SessionServer do
  @moduledoc """
  Runtime process for a single interactive sprite console session.
  """

  use GenServer, restart: :temporary

  import Ecto.Query, warn: false

  alias Fizz.Repo
  alias Fizz.Sprites.Console.Registry, as: ConsoleRegistry
  alias Fizz.Sprites.{SpriteConsoleChunk, SpriteSession}

  @max_buffer_chunks 1000
  @max_buffer_bytes 1_000_000
  @default_grace_seconds 20

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: ConsoleRegistry.via(session_id))
  end

  @spec register_client(String.t(), String.t(), String.t(), String.t(), pid(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def register_client(session_id, user_id, client_id, pane_id, subscriber_pid, focused)
      when is_binary(session_id) and is_binary(user_id) and is_binary(client_id) and
             is_binary(pane_id) and is_pid(subscriber_pid) and is_boolean(focused) do
    GenServer.call(
      ConsoleRegistry.via(session_id),
      {:register_client, user_id, client_id, pane_id, subscriber_pid, focused}
    )
  end

  @spec unregister_client(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def unregister_client(session_id, user_id, client_id)
      when is_binary(session_id) and is_binary(user_id) and is_binary(client_id) do
    GenServer.call(ConsoleRegistry.via(session_id), {:unregister_client, user_id, client_id})
  end

  @spec heartbeat(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def heartbeat(session_id, user_id, client_id, focused)
      when is_binary(session_id) and is_binary(user_id) and is_binary(client_id) and
             is_boolean(focused) do
    GenServer.call(ConsoleRegistry.via(session_id), {:heartbeat, user_id, client_id, focused})
  end

  @spec request_write_lease(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def request_write_lease(session_id, user_id, client_id)
      when is_binary(session_id) and is_binary(user_id) and is_binary(client_id) do
    GenServer.call(ConsoleRegistry.via(session_id), {:request_write_lease, user_id, client_id})
  end

  @spec send_input(String.t(), String.t(), String.t(), iodata()) :: :ok | {:error, term()}
  def send_input(session_id, user_id, client_id, data)
      when is_binary(session_id) and is_binary(user_id) and is_binary(client_id) do
    GenServer.call(ConsoleRegistry.via(session_id), {:input, user_id, client_id, data})
  end

  @spec resize(String.t(), String.t(), String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, term()}
  def resize(session_id, user_id, client_id, rows, cols)
      when is_binary(session_id) and is_binary(user_id) and is_binary(client_id) and
             is_integer(rows) and is_integer(cols) do
    GenServer.call(ConsoleRegistry.via(session_id), {:resize, user_id, client_id, rows, cols})
  end

  @spec replay(String.t(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def replay(session_id, user_id, from_seq, limit \\ 200)
      when is_binary(session_id) and is_binary(user_id) and is_integer(from_seq) and
             from_seq >= 0 and is_integer(limit) and limit > 0 do
    GenServer.call(ConsoleRegistry.via(session_id), {:replay, user_id, from_seq, limit})
  end

  @spec terminate_session(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def terminate_session(session_id, user_id, reason \\ "terminated_by_user")
      when is_binary(session_id) and is_binary(user_id) and is_binary(reason) do
    GenServer.call(ConsoleRegistry.via(session_id), {:terminate, user_id, reason})
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
    grace_seconds = Keyword.get(opts, :grace_seconds, @default_grace_seconds)

    state = %{
      provider_module: provider_module,
      sprite_name: sprite_name,
      session_id: session_id,
      owner_user_id: owner_user_id,
      mode: mode,
      tty: tty,
      grace_seconds: grace_seconds,
      command_handle: nil,
      command_ref: nil,
      interactive_command: Keyword.get(opts, :command, "bash"),
      provider_session_id: Keyword.get(opts, :provider_session_id),
      generation: Keyword.get(opts, :generation, 1),
      runtime_state: "starting",
      grace_timer_ref: nil,
      lease_client_id: nil,
      clients: %{},
      output_buffer: [],
      output_buffer_bytes: 0,
      next_seq: Keyword.get(opts, :next_seq, 1),
      closed_reason: nil
    }

    with {:ok, command_handle} <- start_provider_console(state, opts),
         {:ok, command_ref} <- command_ref(command_handle) do
      provider_session_id = read_provider_session_id(command_handle, state.provider_session_id)
      now = DateTime.utc_now()

      state =
        state
        |> Map.put(:command_handle, command_handle)
        |> Map.put(:command_ref, command_ref)
        |> Map.put(:provider_session_id, provider_session_id)
        |> Map.put(:runtime_state, "attached")

      persist_session_state(state, %{
        provider_session_id: provider_session_id,
        state: "attached",
        generation: state.generation,
        interactive_command: state.interactive_command,
        tty: state.tty,
        last_activity_at: now,
        last_seq: state.next_seq - 1,
        closed_reason: nil,
        exit_code: nil,
        grace_started_at: nil
      })

      {:ok, state}
    else
      {:error, reason} ->
        persist_session_state(state, %{state: "failed", closed_reason: inspect(reason)})
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(
        {:register_client, user_id, client_id, pane_id, subscriber_pid, focused},
        _from,
        state
      ) do
    with :ok <- authorize_owner(state, user_id) do
      now = DateTime.utc_now()

      state =
        state
        |> put_client(client_id, pane_id, subscriber_pid, focused, now)
        |> maybe_reassign_lease(client_id, focused, now)
        |> maybe_recover_attachment(focused)
        |> sync_focus_state()

      {:reply, {:ok, snapshot_payload(state)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unregister_client, user_id, client_id}, _from, state) do
    with :ok <- authorize_owner(state, user_id) do
      state = state |> remove_client(client_id) |> sync_focus_state()
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:heartbeat, user_id, client_id, focused}, _from, state) do
    with :ok <- authorize_owner(state, user_id) do
      now = DateTime.utc_now()

      state =
        state
        |> touch_client(client_id, focused, now)
        |> maybe_reassign_lease(client_id, focused, now)
        |> maybe_recover_attachment(focused)
        |> sync_focus_state()

      {:reply, {:ok, lease_payload(state)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:request_write_lease, user_id, client_id}, _from, state) do
    with :ok <- authorize_owner(state, user_id),
         true <- Map.has_key?(state.clients, client_id) do
      now = DateTime.utc_now()
      state = put_lease(state, client_id, now)
      {:reply, {:ok, lease_payload(state)}, state}
    else
      false -> {:reply, {:error, :client_not_registered}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:input, user_id, client_id, data}, _from, state) do
    with :ok <- authorize_owner(state, user_id),
         :ok <- require_lease_owner(state, client_id),
         {:ok, state} <- ensure_attached(state),
         :ok <- state.provider_module.write_console(state.command_handle, data) do
      now = DateTime.utc_now()
      persist_session_state(state, %{last_activity_at: now, state: "attached"})
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resize, user_id, client_id, rows, cols}, _from, state) do
    with :ok <- authorize_owner(state, user_id),
         :ok <- require_lease_owner(state, client_id),
         {:ok, state} <- ensure_attached(state),
         :ok <- state.provider_module.resize_console(state.command_handle, rows, cols) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:replay, user_id, from_seq, limit}, _from, state) do
    with :ok <- authorize_owner(state, user_id) do
      chunks =
        state.output_buffer
        |> Enum.filter(&(&1.seq > from_seq))
        |> Enum.take(limit)

      {:reply, {:ok, chunks}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:terminate, user_id, reason}, _from, state) do
    with :ok <- authorize_owner(state, user_id),
         :ok <- terminate_provider_session(state, reason) do
      now = DateTime.utc_now()

      persist_session_state(state, %{
        state: "ended",
        closed_reason: reason,
        last_activity_at: now,
        grace_started_at: nil
      })

      broadcast(state, %{
        type: "session_exit",
        session_id: state.session_id,
        reason: reason,
        exit_code: nil,
        generation: state.generation
      })

      {:stop, :normal, :ok, %{state | runtime_state: "ended", closed_reason: reason}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:snapshot, user_id}, _from, state) do
    with :ok <- authorize_owner(state, user_id) do
      {:reply, {:ok, snapshot_payload(state)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    client_id =
      Enum.find_value(state.clients, fn {id, client} ->
        if client.monitor_ref == monitor_ref, do: id
      end)

    state =
      if is_binary(client_id) do
        state |> remove_client(client_id) |> sync_focus_state()
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:stdout, %{ref: ref}, data}, %{command_ref: ref} = state) do
    {:noreply, push_output(state, "stdout", data)}
  end

  def handle_info({:stderr, %{ref: ref}, data}, %{command_ref: ref} = state) do
    {:noreply, push_output(state, "stderr", data)}
  end

  def handle_info({:exit, %{ref: ref}, exit_code}, %{command_ref: ref} = state) do
    state = mark_ended(state, "command_exit", exit_code)
    {:stop, :normal, state}
  end

  def handle_info({:error, %{ref: ref}, reason}, %{command_ref: ref} = state) do
    state = mark_ended(state, inspect(reason), nil)
    {:stop, :normal, state}
  end

  def handle_info(:grace_detach_timeout, state) do
    state =
      if has_focused_clients?(state) do
        state
      else
        detach_stream(state)
      end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.clients, fn {_client_id, client} ->
      if is_reference(client.monitor_ref) do
        Process.demonitor(client.monitor_ref, [:flush])
      end
    end)

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

  defp ensure_attached(%{command_handle: command_handle} = state) when not is_nil(command_handle),
    do: {:ok, state}

  defp ensure_attached(state) do
    case state.provider_module.attach_console(
           state.sprite_name,
           state.provider_session_id,
           tty: state.tty,
           owner: self()
         ) do
      {:ok, command_handle} ->
        with {:ok, ref} <- command_ref(command_handle) do
          now = DateTime.utc_now()

          state =
            state
            |> cancel_grace_timer()
            |> Map.put(:command_handle, command_handle)
            |> Map.put(:command_ref, ref)
            |> Map.put(:runtime_state, "attached")

          persist_session_state(state, %{
            state: "attached",
            grace_started_at: nil,
            last_activity_at: now
          })

          broadcast(state, %{
            type: "session_state",
            session_id: state.session_id,
            state: "attached",
            generation: state.generation,
            reason: "reattached"
          })

          {:ok, state}
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp terminate_provider_session(%{provider_session_id: provider_session_id} = state, _reason)
       when is_binary(provider_session_id) and provider_session_id != "" do
    state.provider_module.kill_session(state.sprite_name, provider_session_id)
  end

  defp terminate_provider_session(%{command_handle: command_handle} = state, _reason)
       when not is_nil(command_handle) do
    state.provider_module.detach_console(command_handle)
  end

  defp terminate_provider_session(_state, _reason), do: :ok

  defp detach_stream(%{command_handle: nil} = state), do: state

  defp detach_stream(state) do
    case state.provider_module.detach_console(state.command_handle) do
      :ok ->
        now = DateTime.utc_now()

        state =
          state
          |> Map.put(:command_handle, nil)
          |> Map.put(:command_ref, nil)
          |> Map.put(:runtime_state, "detached")
          |> cancel_grace_timer()

        persist_session_state(state, %{state: "detached", grace_started_at: now})

        broadcast(state, %{
          type: "session_state",
          session_id: state.session_id,
          state: "detached",
          generation: state.generation,
          reason: "grace_timeout"
        })

        state

      {:error, reason} ->
        mark_ended(state, inspect(reason), nil)
    end
  end

  defp push_output(state, stream, data) do
    chunk = %{seq: state.next_seq, stream: stream, data: to_string(data)}

    state =
      state
      |> append_chunk(chunk)
      |> Map.put(:next_seq, state.next_seq + 1)

    persist_chunk(state, chunk)

    now = DateTime.utc_now()

    persist_session_state(state, %{
      last_seq: chunk.seq,
      last_activity_at: now,
      state: if(state.runtime_state == "detached", do: "detached", else: "attached")
    })

    broadcast_focused(state, %{
      type: "output_chunk",
      session_id: state.session_id,
      generation: state.generation,
      chunk: chunk
    })

    state
  end

  defp mark_ended(state, reason, exit_code) do
    now = DateTime.utc_now()

    persist_session_state(state, %{
      state: "ended",
      closed_reason: reason,
      exit_code: exit_code,
      last_activity_at: now,
      grace_started_at: nil
    })

    broadcast(state, %{
      type: "session_exit",
      session_id: state.session_id,
      reason: reason,
      exit_code: exit_code,
      generation: state.generation
    })

    %{state | runtime_state: "ended", closed_reason: reason}
  end

  defp put_client(state, client_id, pane_id, subscriber_pid, focused, now) do
    state = remove_client(state, client_id)

    monitor_ref = Process.monitor(subscriber_pid)

    client = %{
      pane_id: pane_id,
      subscriber_pid: subscriber_pid,
      monitor_ref: monitor_ref,
      focused: focused,
      last_heartbeat_at: now
    }

    %{state | clients: Map.put(state.clients, client_id, client)}
  end

  defp touch_client(state, client_id, focused, now) do
    clients =
      Map.update(state.clients, client_id, nil, fn
        nil ->
          nil

        client ->
          %{client | focused: focused, last_heartbeat_at: now}
      end)

    %{
      state
      | clients: clients |> Enum.reject(fn {_id, client} -> is_nil(client) end) |> Map.new()
    }
  end

  defp remove_client(state, client_id) do
    case Map.pop(state.clients, client_id) do
      {nil, _clients} ->
        state

      {client, clients} ->
        if is_reference(client.monitor_ref) do
          Process.demonitor(client.monitor_ref, [:flush])
        end

        %{state | clients: clients}
    end
  end

  defp maybe_reassign_lease(state, client_id, true, now), do: put_lease(state, client_id, now)
  defp maybe_reassign_lease(state, _client_id, false, _now), do: state

  defp put_lease(state, client_id, now) do
    if state.lease_client_id == client_id do
      state
    else
      persist_session_state(state, %{lease_client_id: client_id, lease_acquired_at: now})

      broadcast(state, %{
        type: "lease_changed",
        session_id: state.session_id,
        generation: state.generation,
        lease_client_id: client_id
      })

      %{state | lease_client_id: client_id}
    end
  end

  defp maybe_recover_attachment(state, true) do
    case ensure_attached(state) do
      {:ok, state} -> state
      {:error, _reason} -> state
    end
  end

  defp maybe_recover_attachment(state, false), do: state

  defp sync_focus_state(state) do
    if has_focused_clients?(state) do
      state
      |> cancel_grace_timer()
      |> maybe_mark_attached_from_grace()
    else
      state
      |> maybe_release_lease_to_focused()
      |> ensure_grace_timer()
    end
  end

  defp maybe_mark_attached_from_grace(%{runtime_state: runtime_state} = state)
       when runtime_state in ["grace_detaching", "detached"] do
    case ensure_attached(state) do
      {:ok, state} -> state
      {:error, _reason} -> state
    end
  end

  defp maybe_mark_attached_from_grace(state), do: state

  defp maybe_release_lease_to_focused(state) do
    next_lease =
      state.clients
      |> Enum.filter(fn {_id, client} -> client.focused end)
      |> Enum.max_by(
        fn {_id, client} -> DateTime.to_unix(client.last_heartbeat_at, :microsecond) end,
        fn -> nil end
      )
      |> case do
        {client_id, _client} -> client_id
        nil -> nil
      end

    if next_lease == state.lease_client_id do
      state
    else
      persist_session_state(state, %{lease_client_id: next_lease})

      broadcast(state, %{
        type: "lease_changed",
        session_id: state.session_id,
        generation: state.generation,
        lease_client_id: next_lease
      })

      %{state | lease_client_id: next_lease}
    end
  end

  defp ensure_grace_timer(%{runtime_state: runtime_state} = state)
       when runtime_state in ["detached", "ended", "failed"] do
    state
  end

  defp ensure_grace_timer(%{grace_timer_ref: grace_timer_ref} = state)
       when is_reference(grace_timer_ref),
       do: state

  defp ensure_grace_timer(state) do
    ref = Process.send_after(self(), :grace_detach_timeout, state.grace_seconds * 1000)
    now = DateTime.utc_now()

    persist_session_state(state, %{state: "grace_detaching", grace_started_at: now})

    broadcast(state, %{
      type: "session_state",
      session_id: state.session_id,
      state: "grace_detaching",
      generation: state.generation,
      reason: "no_focused_clients"
    })

    %{state | runtime_state: "grace_detaching", grace_timer_ref: ref}
  end

  defp cancel_grace_timer(state) do
    if is_reference(state.grace_timer_ref) do
      Process.cancel_timer(state.grace_timer_ref, async: true, info: false)
      persist_session_state(state, %{grace_started_at: nil, state: "attached"})
      %{state | grace_timer_ref: nil, runtime_state: "attached"}
    else
      state
    end
  end

  defp require_lease_owner(%{lease_client_id: lease_client_id}, client_id)
       when is_binary(lease_client_id) and lease_client_id == client_id,
       do: :ok

  defp require_lease_owner(_state, _client_id), do: {:error, :write_lease_required}

  defp has_focused_clients?(state) do
    Enum.any?(state.clients, fn {_id, client} -> client.focused end)
  end

  defp snapshot_payload(state) do
    %{
      id: state.session_id,
      provider_session_id: state.provider_session_id,
      command: state.interactive_command,
      tty: state.tty,
      state: state.runtime_state,
      generation: state.generation,
      lease_client_id: state.lease_client_id,
      last_seq: state.next_seq - 1,
      chunks: state.output_buffer
    }
  end

  defp lease_payload(state) do
    %{
      session_id: state.session_id,
      generation: state.generation,
      lease_client_id: state.lease_client_id,
      state: state.runtime_state
    }
  end

  defp append_chunk(state, chunk) do
    chunk_size = byte_size(chunk.data)
    output_buffer = state.output_buffer ++ [chunk]
    output_buffer_bytes = state.output_buffer_bytes + chunk_size

    {output_buffer, output_buffer_bytes} =
      trim_buffer(output_buffer, output_buffer_bytes, length(output_buffer))

    %{state | output_buffer: output_buffer, output_buffer_bytes: output_buffer_bytes}
  end

  defp trim_buffer(output_buffer, output_buffer_bytes, output_buffer_len)
       when output_buffer_len <= @max_buffer_chunks and output_buffer_bytes <= @max_buffer_bytes do
    {output_buffer, output_buffer_bytes}
  end

  defp trim_buffer([oldest | rest], output_buffer_bytes, output_buffer_len) do
    trim_buffer(
      rest,
      output_buffer_bytes - byte_size(oldest.data),
      output_buffer_len - 1
    )
  end

  defp trim_buffer([], output_buffer_bytes, _len), do: {[], max(output_buffer_bytes, 0)}

  defp persist_chunk(state, chunk) do
    %SpriteConsoleChunk{}
    |> SpriteConsoleChunk.changeset(%{
      sprite_session_id: state.session_id,
      seq: chunk.seq,
      stream: chunk.stream,
      data: chunk.data
    })
    |> Repo.insert(on_conflict: :nothing)

    maybe_prune_chunks(state.session_id, chunk.seq)

    :ok
  end

  defp maybe_prune_chunks(_session_id, seq) when rem(seq, 100) != 0, do: :ok

  defp maybe_prune_chunks(session_id, _seq) do
    cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)

    Repo.delete_all(
      from(chunk in SpriteConsoleChunk,
        where: chunk.sprite_session_id == ^session_id and chunk.inserted_at < ^cutoff
      )
    )

    :ok
  end

  defp persist_session_state(state, attrs) when is_map(attrs) do
    set_fields =
      attrs
      |> Enum.reject(fn {_k, v} -> is_nil(v) and false end)

    if set_fields != [] do
      now = DateTime.utc_now()

      Repo.update_all(
        from(session in SpriteSession, where: session.id == ^state.session_id),
        set: Keyword.put(set_fields, :updated_at, now)
      )
    end

    :ok
  end

  defp broadcast(state, event) do
    Enum.each(state.clients, fn {_id, client} ->
      if is_pid(client.subscriber_pid) do
        send(client.subscriber_pid, {:console_session_event, state.session_id, event})
      end
    end)

    :ok
  end

  defp broadcast_focused(state, event) do
    Enum.each(state.clients, fn {_id, client} ->
      if client.focused and is_pid(client.subscriber_pid) do
        send(client.subscriber_pid, {:console_session_event, state.session_id, event})
      end
    end)

    :ok
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

  defp authorize_owner(%{owner_user_id: owner_user_id}, owner_user_id), do: :ok
  defp authorize_owner(_state, _user_id), do: {:error, :forbidden}
end
