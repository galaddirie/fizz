defmodule Fizz.Sprites.Broker do
  @moduledoc """
  High-level access to per-workspace sprite broker servers.
  """

  alias Fizz.Sprites.Workspace
  alias Fizz.Sprites.Broker.WorkspaceServer

  @default_timeout 120_000

  @spec ensure_sprite(Workspace.t()) :: {:ok, map()} | {:error, term()}
  def ensure_sprite(%Workspace{} = workspace) do
    call_workspace(workspace, :ensure_sprite)
  end

  @spec destroy_sprite(Workspace.t()) :: :ok | {:error, term()}
  def destroy_sprite(%Workspace{} = workspace) do
    call_workspace(workspace, :destroy_sprite)
  end

  @spec sprite_info(Workspace.t()) :: {:ok, map()} | {:error, term()}
  def sprite_info(%Workspace{} = workspace) do
    call_workspace(workspace, :sprite_info)
  end

  @spec exec_shell(Workspace.t(), String.t(), keyword()) ::
          {:ok, %{stdout: binary(), exit_code: non_neg_integer()}} | {:error, term()}
  def exec_shell(%Workspace{} = workspace, shell_command, opts \\ [])
      when is_binary(shell_command) do
    call_workspace(workspace, {:exec_shell, shell_command, opts})
  end

  @spec spawn_console(Workspace.t(), pid(), keyword()) :: {:ok, term()} | {:error, term()}
  def spawn_console(%Workspace{} = workspace, owner, opts \\ []) when is_pid(owner) do
    call_workspace(workspace, {:spawn_console, owner, opts})
  end

  @spec attach_console(Workspace.t(), String.t(), pid(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def attach_console(%Workspace{} = workspace, session_id, owner, opts \\ [])
      when is_binary(session_id) and is_pid(owner) do
    call_workspace(workspace, {:attach_console, session_id, owner, opts})
  end

  @spec list_sessions(Workspace.t()) :: {:ok, [term()]} | {:error, term()}
  def list_sessions(%Workspace{} = workspace) do
    call_workspace(workspace, :list_sessions)
  end

  @spec list_checkpoints(Workspace.t()) :: {:ok, [term()]} | {:error, term()}
  def list_checkpoints(%Workspace{} = workspace) do
    call_workspace(workspace, :list_checkpoints)
  end

  @spec create_checkpoint(Workspace.t(), String.t() | nil) :: {:ok, [term()]} | {:error, term()}
  def create_checkpoint(%Workspace{} = workspace, comment \\ nil) do
    call_workspace(workspace, {:create_checkpoint, comment})
  end

  @spec restore_checkpoint(Workspace.t(), String.t()) :: {:ok, [term()]} | {:error, term()}
  def restore_checkpoint(%Workspace{} = workspace, checkpoint_id) when is_binary(checkpoint_id) do
    call_workspace(workspace, {:restore_checkpoint, checkpoint_id})
  end

  defp call_workspace(%Workspace{} = workspace, message) do
    with {:ok, pid} <- workspace_server(workspace) do
      GenServer.call(pid, message, @default_timeout)
    end
  end

  defp workspace_server(%Workspace{workspace_id: workspace_id} = workspace) do
    case Registry.lookup(Fizz.Sprites.Broker.Registry, workspace_id) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        start_workspace_server(workspace)
    end
  end

  defp start_workspace_server(%Workspace{} = workspace) do
    child_spec = {WorkspaceServer, workspace: workspace}

    case DynamicSupervisor.start_child(Fizz.Sprites.Broker.WorkspaceSupervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {:already_present, _child_id}} -> fetch_started_pid(workspace)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_started_pid(%Workspace{workspace_id: workspace_id}) do
    case Registry.lookup(Fizz.Sprites.Broker.Registry, workspace_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :workspace_server_not_found}
    end
  end
end
