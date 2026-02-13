defmodule Fizz.Sprites.Broker.WorkspaceServer do
  @moduledoc """
  Serializes all sprite operations for a workspace.
  """

  use GenServer

  alias Fizz.Sprites.Config
  alias Fizz.Sprites.Workspace

  def start_link(opts) do
    workspace = Keyword.fetch!(opts, :workspace)

    GenServer.start_link(__MODULE__, %{workspace: workspace},
      name: via_tuple(workspace.workspace_id)
    )
  end

  @impl true
  def init(%{workspace: %Workspace{} = workspace}) do
    state =
      if Config.configured?() do
        client = sprites_sdk().new(Config.api_key(), base_url: Config.base_url())
        sprite = sprites_sdk().sprite(client, workspace.sprite_name)

        %{
          workspace: workspace,
          client: client,
          sprite: sprite
        }
      else
        %{
          workspace: workspace,
          client: nil,
          sprite: nil
        }
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:ensure_sprite, _from, state) do
    reply =
      with {:ok, state} <- ensure_ready_state(state),
           {:ok, sprite_info, _state} <- ensure_sprite_exists(state) do
        {:ok, sprite_info}
      end

    {:reply, reply, state}
  end

  def handle_call(:destroy_sprite, _from, state) do
    reply =
      with {:ok, state} <- ensure_ready_state(state),
           :ok <- sprites_sdk().destroy(state.sprite) do
        :ok
      end

    {:reply, reply, state}
  end

  def handle_call(:sprite_info, _from, state) do
    reply =
      with {:ok, state} <- ensure_ready_state(state),
           {:ok, sprite_info} <-
             sprites_sdk().get_sprite(state.client, state.workspace.sprite_name) do
        {:ok, sprite_info}
      end

    {:reply, reply, state}
  end

  def handle_call({:exec_shell, shell_command, opts}, _from, state) do
    reply =
      with {:ok, state} <- ensure_ready_state(state),
           {:ok, _sprite_info, state} <- ensure_sprite_exists(state),
           {:ok, result} <- execute_shell(state, shell_command, opts) do
        {:ok, result}
      end

    {:reply, reply, state}
  end

  def handle_call({:spawn_console, owner, opts}, _from, state) do
    reply =
      with {:ok, state} <- ensure_ready_state(state),
           {:ok, _sprite_info, state} <- ensure_sprite_exists(state),
           {:ok, command} <- spawn_console_command(state, owner, opts) do
        {:ok, command}
      end

    {:reply, reply, state}
  end

  def handle_call({:attach_console, session_id, owner, opts}, _from, state) do
    reply =
      with {:ok, state} <- ensure_ready_state(state),
           {:ok, _sprite_info, state} <- ensure_sprite_exists(state),
           {:ok, command} <- attach_console_session(state, session_id, owner, opts) do
        {:ok, command}
      end

    {:reply, reply, state}
  end

  def handle_call(:list_sessions, _from, state) do
    reply =
      with {:ok, state} <- ensure_ready_state(state),
           {:ok, _sprite_info, state} <- ensure_sprite_exists(state),
           {:ok, sessions} <- sprites_sdk().list_sessions(state.sprite) do
        {:ok, sessions}
      end

    {:reply, reply, state}
  end

  def handle_call(:list_checkpoints, _from, state) do
    reply =
      with {:ok, state} <- ensure_ready_state(state),
           {:ok, _sprite_info, state} <- ensure_sprite_exists(state),
           {:ok, checkpoints} <- sprites_sdk().list_checkpoints(state.sprite, []) do
        {:ok, checkpoints}
      end

    {:reply, reply, state}
  end

  def handle_call({:create_checkpoint, comment}, _from, state) do
    reply =
      with {:ok, state} <- ensure_ready_state(state),
           {:ok, _sprite_info, state} <- ensure_sprite_exists(state),
           {:ok, messages} <- create_checkpoint_messages(state, comment) do
        {:ok, messages}
      end

    {:reply, reply, state}
  end

  def handle_call({:restore_checkpoint, checkpoint_id}, _from, state) do
    reply =
      with {:ok, state} <- ensure_ready_state(state),
           {:ok, _sprite_info, state} <- ensure_sprite_exists(state),
           {:ok, messages} <- restore_checkpoint_messages(state, checkpoint_id) do
        {:ok, messages}
      end

    {:reply, reply, state}
  end

  defp ensure_ready_state(%{client: nil}), do: {:error, :sprites_not_configured}
  defp ensure_ready_state(state), do: {:ok, state}

  defp ensure_sprite_exists(state) do
    case sprites_sdk().get_sprite(state.client, state.workspace.sprite_name) do
      {:ok, sprite_info} ->
        {:ok, sprite_info, state}

      {:error, reason} ->
        maybe_create_sprite(state, reason)
    end
  end

  defp maybe_create_sprite(state, reason) do
    if sprite_not_found?(reason) do
      case sprites_sdk().create(state.client, state.workspace.sprite_name, []) do
        {:ok, _sprite} ->
          sprites_sdk().get_sprite(state.client, state.workspace.sprite_name)
          |> case do
            {:ok, sprite_info} -> {:ok, sprite_info, state}
            {:error, create_reason} -> {:error, create_reason}
          end

        {:error, create_reason} ->
          if sprite_conflict?(create_reason) do
            case sprites_sdk().get_sprite(state.client, state.workspace.sprite_name) do
              {:ok, sprite_info} -> {:ok, sprite_info, state}
              {:error, get_reason} -> {:error, get_reason}
            end
          else
            {:error, create_reason}
          end
      end
    else
      {:error, reason}
    end
  end

  defp execute_shell(state, shell_command, opts) do
    timeout = Keyword.get(opts, :timeout, Config.cmd_timeout_ms())
    dir = Keyword.get(opts, :dir)
    env = Keyword.get(opts, :env, [])

    command_opts =
      []
      |> Keyword.put(:timeout, timeout)
      |> Keyword.put(:stderr_to_stdout, true)
      |> maybe_put(:dir, dir)
      |> maybe_put(:env, env)

    try do
      {output, exit_code} =
        sprites_sdk().cmd(state.sprite, "bash", ["-lc", shell_command], command_opts)

      {:ok, %{stdout: output, exit_code: exit_code}}
    rescue
      error ->
        {:error, {:exec_failed, Exception.message(error)}}
    end
  end

  defp spawn_console_command(state, owner, opts) do
    rows = Keyword.get(opts, :rows, 28)
    cols = Keyword.get(opts, :cols, 120)
    detachable = Keyword.get(opts, :detachable, false)

    spawn_opts = [
      owner: owner,
      tty: true,
      stdin: true,
      tty_rows: rows,
      tty_cols: cols,
      detachable: detachable
    ]

    sprites_sdk().spawn(state.sprite, "bash", ["-i"], spawn_opts)
  end

  defp attach_console_session(state, session_id, owner, opts) do
    rows = Keyword.get(opts, :rows, 28)
    cols = Keyword.get(opts, :cols, 120)

    attach_opts = [owner: owner, tty: true, stdin: true, tty_rows: rows, tty_cols: cols]

    sprites_sdk().attach_session(state.sprite, session_id, attach_opts)
  end

  defp create_checkpoint_messages(state, comment) do
    opts =
      case normalize_comment(comment) do
        nil -> []
        normalized -> [comment: normalized]
      end

    with {:ok, messages} <- sprites_sdk().create_checkpoint(state.sprite, opts) do
      {:ok, Enum.to_list(messages)}
    end
  end

  defp restore_checkpoint_messages(state, checkpoint_id) do
    with {:ok, messages} <- sprites_sdk().restore_checkpoint(state.sprite, checkpoint_id) do
      {:ok, Enum.to_list(messages)}
    end
  end

  defp normalize_comment(comment) when is_binary(comment) do
    trimmed = String.trim(comment)

    if trimmed == "" do
      nil
    else
      trimmed
    end
  end

  defp normalize_comment(_comment), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp sprite_not_found?({:not_found, _body}), do: true
  defp sprite_not_found?({:api_error, 404, _body}), do: true
  defp sprite_not_found?(%Sprites.Error.APIError{status: 404}), do: true
  defp sprite_not_found?(_reason), do: false

  defp sprite_conflict?({:api_error, 409, _body}), do: true
  defp sprite_conflict?(%Sprites.Error.APIError{status: 409}), do: true
  defp sprite_conflict?(_reason), do: false

  defp via_tuple(workspace_id),
    do: {:via, Registry, {Fizz.Sprites.Broker.Registry, workspace_id}}

  defp sprites_sdk do
    Application.get_env(:fizz, :sprites_sdk_module, Fizz.Integrations.SpritesSDK.Live)
  end
end
