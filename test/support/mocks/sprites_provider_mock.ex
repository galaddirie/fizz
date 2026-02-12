defmodule Fizz.SpritesProviderMock do
  @moduledoc false

  @behaviour Fizz.Sprites.Provider

  @owner_key {__MODULE__, :owner}
  @store_key {__MODULE__, :store}

  def configure(owner, store_pid) when is_pid(owner) and is_pid(store_pid) do
    :persistent_term.put(@owner_key, owner)
    :persistent_term.put(@store_key, store_pid)
    :ok
  end

  def reset do
    :persistent_term.erase(@owner_key)
    :persistent_term.erase(@store_key)
    :ok
  end

  def put_responses(key, responses) when is_atom(key) and is_list(responses) do
    Agent.update(store_pid!(), fn state -> Map.put(state, key, responses) end)
  end

  @impl true
  def configured?, do: true

  @impl true
  def create_sprite(name, config) do
    notify({:create_sprite, name, config})
    next_response(:create_sprite, {:ok, %{"name" => name, "status" => "ready"}})
  end

  @impl true
  def destroy_sprite(name) do
    notify({:destroy_sprite, name})
    next_response(:destroy_sprite, :ok)
  end

  @impl true
  def get_sprite(name) do
    notify({:get_sprite, name})
    next_response(:get_sprite, {:ok, %{"name" => name, "status" => "ready", "url" => nil}})
  end

  @impl true
  def run_command(name, command, args, opts) do
    notify({:run_command, name, command, args, opts})
    next_response(:run_command, {:ok, %{output: "ok\n", exit_code: 0}})
  end

  @impl true
  def start_console(name, command, args, opts) do
    owner = Keyword.fetch!(opts, :owner)
    ref = make_ref()
    provider_session_id = "mock-session-#{System.unique_integer([:positive])}"
    handle = %{ref: ref, owner: owner, provider_session_id: provider_session_id}
    notify({:start_console, name, command, args})
    response = next_response(:start_console, {:ok, handle})

    case response do
      {:ok, :auto_stream} ->
        send(owner, {:stdout, %{ref: ref}, "console started\n"})
        {:ok, handle}

      {:ok, returned_handle} when is_map(returned_handle) ->
        {:ok, Map.merge(handle, returned_handle)}

      other ->
        other
    end
  end

  @impl true
  def attach_console(name, provider_session_id, opts) do
    owner = Keyword.fetch!(opts, :owner)
    ref = make_ref()
    handle = %{ref: ref, owner: owner, provider_session_id: provider_session_id}
    notify({:attach_console, name, provider_session_id})
    response = next_response(:attach_console, {:ok, handle})

    case response do
      {:ok, returned_handle} when is_map(returned_handle) ->
        {:ok, Map.merge(handle, returned_handle)}

      other ->
        other
    end
  end

  @impl true
  def write_console(command_handle, data) do
    notify({:write_console, command_handle, data})

    case command_handle do
      %{owner: owner, ref: ref} ->
        send(owner, {:stdout, %{ref: ref}, IO.iodata_to_binary(data)})
        :ok

      _ ->
        :ok
    end
  end

  @impl true
  def resize_console(command_handle, rows, cols) do
    notify({:resize_console, command_handle, rows, cols})
    :ok
  end

  @impl true
  def close_console(command_handle) do
    notify({:close_console, command_handle})

    case command_handle do
      %{owner: owner, ref: ref} ->
        send(owner, {:exit, %{ref: ref}, 0})
        :ok

      _ ->
        :ok
    end
  end

  @impl true
  def await_console(_command_handle, _timeout) do
    {:ok, 0}
  end

  @impl true
  def list_sessions(name) do
    notify({:list_sessions, name})
    next_response(:list_sessions, {:ok, []})
  end

  @impl true
  def list_checkpoints(name) do
    notify({:list_checkpoints, name})
    next_response(:list_checkpoints, {:ok, []})
  end

  @impl true
  def get_checkpoint(name, checkpoint_id) do
    notify({:get_checkpoint, name, checkpoint_id})

    next_response(
      :get_checkpoint,
      {:ok, %{id: checkpoint_id, create_time: nil, history: [], comment: nil}}
    )
  end

  @impl true
  def create_checkpoint(name, opts) do
    notify({:create_checkpoint, name, opts})
    next_response(:create_checkpoint, {:ok, []})
  end

  @impl true
  def restore_checkpoint(name, checkpoint_id) do
    notify({:restore_checkpoint, name, checkpoint_id})
    next_response(:restore_checkpoint, {:ok, []})
  end

  @impl true
  def get_network_policy(name) do
    notify({:get_network_policy, name})
    next_response(:get_network_policy, {:ok, %{rules: [%{domain: "*", action: "deny"}]}})
  end

  @impl true
  def update_network_policy(name, policy) do
    notify({:update_network_policy, name, policy})
    next_response(:update_network_policy, :ok)
  end

  @impl true
  def get_url_settings(name) do
    notify({:get_url_settings, name})
    next_response(:get_url_settings, {:ok, %{url: nil, auth: "bearer"}})
  end

  @impl true
  def update_url_settings(name, settings) do
    notify({:update_url_settings, name, settings})
    next_response(:update_url_settings, :ok)
  end

  defp next_response(key, default) do
    Agent.get_and_update(store_pid!(), fn state ->
      queue = Map.get(state, key, [])

      case queue do
        [response | rest] ->
          {response, Map.put(state, key, rest)}

        [] ->
          {default, state}
      end
    end)
  end

  defp notify(message) do
    case :persistent_term.get(@owner_key, nil) do
      owner when is_pid(owner) ->
        send(owner, {:sprites_provider_call, message})
        :ok

      _ ->
        :ok
    end
  end

  defp store_pid! do
    case :persistent_term.get(@store_key, nil) do
      store_pid when is_pid(store_pid) -> store_pid
      _ -> raise "SpritesProviderMock is not configured"
    end
  end
end
