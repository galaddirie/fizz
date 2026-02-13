defmodule Fizz.SpritesSDKMock do
  @moduledoc false

  @behaviour Fizz.Integrations.SpritesSDK

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

  def put_response(method, response) when is_atom(method) do
    put_responses(method, [response])
  end

  def put_responses(method, responses) when is_atom(method) and is_list(responses) do
    Agent.update(store_pid!(), fn state ->
      Map.put(state, method, responses)
    end)
  end

  def put_responses(responses_by_method) when is_map(responses_by_method) do
    normalized =
      Enum.into(responses_by_method, %{}, fn {method, responses} ->
        {method, List.wrap(responses)}
      end)

    Agent.update(store_pid!(), fn _state -> normalized end)
  end

  def build_command(owner \\ self()) do
    pid = spawn(fn -> await_stop() end)
    %{ref: make_ref(), pid: pid, owner: owner}
  end

  def emit_stdout(%{owner: owner, ref: ref}, data) when is_pid(owner) do
    send(owner, {:stdout, %{ref: ref}, data})
    :ok
  end

  def emit_stderr(%{owner: owner, ref: ref}, data) when is_pid(owner) do
    send(owner, {:stderr, %{ref: ref}, data})
    :ok
  end

  def emit_exit(%{owner: owner, ref: ref}, code) when is_pid(owner) do
    send(owner, {:exit, %{ref: ref}, code})
    :ok
  end

  def emit_error(%{owner: owner, ref: ref}, reason) when is_pid(owner) do
    send(owner, {:error, %{ref: ref}, reason})
    :ok
  end

  @impl true
  def new(token, opts) do
    dispatch(:new, [token, opts], fn ->
      %{token: token, opts: opts}
    end)
  end

  @impl true
  def sprite(client, name) do
    dispatch(:sprite, [client, name], fn ->
      %{client: client, name: name}
    end)
  end

  @impl true
  def list(client, opts) do
    dispatch(:list, [client, opts], fn -> {:ok, []} end)
  end

  @impl true
  def get_sprite(client, name) do
    dispatch(:get_sprite, [client, name], fn ->
      {:ok, %{name: name, status: "running"}}
    end)
  end

  @impl true
  def create(client, name, opts) do
    dispatch(:create, [client, name, opts], fn ->
      {:ok, %{name: name}}
    end)
  end

  @impl true
  def destroy(sprite) do
    dispatch(:destroy, [sprite], fn -> :ok end)
  end

  @impl true
  def cmd(sprite, command, args, opts) do
    dispatch(:cmd, [sprite, command, args, opts], fn -> {"", 0} end)
  end

  @impl true
  def spawn(sprite, command, args, opts) do
    dispatch(:spawn, [sprite, command, args, opts], fn ->
      {:ok, build_command(Keyword.get(opts, :owner, self()))}
    end)
  end

  @impl true
  def attach_session(sprite, session_id, opts) do
    dispatch(:attach_session, [sprite, session_id, opts], fn ->
      {:ok, build_command(Keyword.get(opts, :owner, self()))}
    end)
  end

  @impl true
  def list_sessions(sprite) do
    dispatch(:list_sessions, [sprite], fn -> {:ok, []} end)
  end

  @impl true
  def list_checkpoints(sprite, opts) do
    dispatch(:list_checkpoints, [sprite, opts], fn -> {:ok, []} end)
  end

  @impl true
  def create_checkpoint(sprite, opts) do
    dispatch(:create_checkpoint, [sprite, opts], fn -> {:ok, []} end)
  end

  @impl true
  def restore_checkpoint(sprite, checkpoint_id) do
    dispatch(:restore_checkpoint, [sprite, checkpoint_id], fn -> {:ok, []} end)
  end

  @impl true
  def write(command, data) do
    dispatch(:write, [command, data], fn -> :ok end)
  end

  @impl true
  def close_stdin(command) do
    dispatch(:close_stdin, [command], fn -> :ok end)
  end

  @impl true
  def resize(command, rows, cols) do
    dispatch(:resize, [command, rows, cols], fn -> :ok end)
  end

  @impl true
  def await(command, timeout) do
    dispatch(:await, [command, timeout], fn -> {:ok, 0} end)
  end

  defp await_stop do
    receive do
      :stop -> :ok
    end
  end

  defp dispatch(method, args, default_fun) when is_function(default_fun, 0) do
    notify(method, args)

    case pop_response(method) do
      {:ok, response} -> resolve_response(response, args)
      :empty -> default_fun.()
    end
  end

  defp resolve_response({:raise, exception}, _args), do: raise(exception)

  defp resolve_response(response, args) do
    arity = length(args)

    if is_function(response, arity) do
      apply(response, args)
    else
      response
    end
  end

  defp notify(method, args) do
    case :persistent_term.get(@owner_key, nil) do
      owner when is_pid(owner) ->
        send(owner, {:sprites_sdk_call, method, args})
        :ok

      _ ->
        :ok
    end
  end

  defp pop_response(method) do
    Agent.get_and_update(store_pid!(), fn state ->
      case Map.get(state, method, []) do
        [response | rest] -> {{:ok, response}, Map.put(state, method, rest)}
        [] -> {:empty, state}
      end
    end)
  end

  defp store_pid! do
    case :persistent_term.get(@store_key, nil) do
      store_pid when is_pid(store_pid) -> store_pid
      _ -> raise "SpritesSDKMock is not configured"
    end
  end
end
