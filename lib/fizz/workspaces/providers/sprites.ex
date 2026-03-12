defmodule Fizz.Workspaces.Providers.Sprites do
  @moduledoc """
  Sprites-backed workspace runtime provider.
  """

  @behaviour Fizz.Workspaces.Provider

  require Logger

  alias Fizz.Workspaces.ConsoleSession
  alias Fizz.Workspaces.Providers.Sprites.{Client, ConsoleRunner, GitCredentialSetup, Http}

  @impl true
  def provider_id, do: "sprites"

  @impl true
  def exec_timeout_ms_default, do: Client.exec_timeout_ms_default()

  @impl true
  def log_retention_days, do: Client.log_retention_days()

  @impl true
  def checkpoint_retention_days, do: Client.checkpoint_retention_days()

  @impl true
  def service_log_tail_lines, do: Client.service_log_tail_lines()

  @impl true
  def create_workspace(remote_name, attrs) when is_binary(remote_name) and is_map(attrs) do
    with {:ok, client} <- Client.client(),
         {:ok, remote_workspace} <-
           Sprites.create(client, remote_name, config: Map.get(attrs, :config, %{})) do
      {:ok,
       %{
         id: Map.get(remote_workspace, :id),
         url: Map.get(remote_workspace, :url)
       }}
    end
  end

  @impl true
  def delete_workspace(remote_name) when is_binary(remote_name) do
    with {:ok, remote_workspace} <- Client.workspace(remote_name) do
      Sprites.destroy(remote_workspace)
    end
  end

  @impl true
  def update_url_auth(remote_name, mode) when is_binary(remote_name) do
    auth =
      case mode do
        :public -> "none"
        :bearer -> "bearer"
        :default -> "bearer"
      end

    case Http.update_workspace_url_settings(remote_name, %{auth: auth}) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def apply_network_policy(remote_name, allowlist)
      when is_binary(remote_name) and is_list(allowlist) do
    with {:ok, remote_workspace} <- Client.workspace(remote_name) do
      rules =
        allowlist
        |> Enum.map(fn domain ->
          %Sprites.Policy.Rule{domain: domain, action: "allow"}
        end)
        |> Kernel.++([%Sprites.Policy.Rule{domain: "*", action: "deny"}])

      policy = %Sprites.Policy{rules: rules}

      case Sprites.update_network_policy(remote_workspace, policy) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("failed to apply default network policy: #{inspect(reason)}")
          :ok
      end
    else
      {:error, reason} ->
        Logger.warning("failed to load remote workspace for network policy: #{inspect(reason)}")
        :ok
    end
  rescue
    _exception ->
      :ok
  end

  @impl true
  def start_exec(remote_name, command, args, opts)
      when is_binary(remote_name) and is_binary(command) and is_list(args) and is_list(opts) do
    with {:ok, remote_workspace} <- Client.workspace(remote_name) do
      Sprites.spawn(remote_workspace, command, args, opts)
    end
  end

  @impl true
  def kill_exec_session(remote_name, session_id)
      when is_binary(remote_name) and is_binary(session_id) do
    Http.kill_exec_session(remote_name, session_id)
  end

  @impl true
  def start_console_runner(%ConsoleSession{} = console_session, channel_pid, env)
      when is_pid(channel_pid) and is_list(env) do
    ConsoleRunner.start_link(
      console_id: console_session.id,
      remote_name: console_session.workspace.remote_name,
      channel_pid: channel_pid,
      rows: console_session.rows,
      cols: console_session.cols,
      env: env
    )
  end

  @impl true
  def setup_git_credentials(remote_name, access_token, opts)
      when is_binary(remote_name) and is_binary(access_token) and is_list(opts) do
    GitCredentialSetup.setup(remote_name, access_token, opts)
  end

  @impl true
  def list_services(remote_name) when is_binary(remote_name) do
    Http.list_services(remote_name)
  end

  @impl true
  def get_service(remote_name, service_name)
      when is_binary(remote_name) and is_binary(service_name) do
    Http.get_service(remote_name, service_name)
  end

  @impl true
  def put_service(remote_name, service_name, body)
      when is_binary(remote_name) and is_binary(service_name) and is_map(body) do
    Http.put_service(remote_name, service_name, body)
  end

  @impl true
  def start_service(remote_name, service_name)
      when is_binary(remote_name) and is_binary(service_name) do
    Http.start_service(remote_name, service_name)
  end

  @impl true
  def stop_service(remote_name, service_name)
      when is_binary(remote_name) and is_binary(service_name) do
    Http.stop_service(remote_name, service_name)
  end

  @impl true
  def service_logs(remote_name, service_name, opts)
      when is_binary(remote_name) and is_binary(service_name) and is_list(opts) do
    Http.service_logs(remote_name, service_name, opts)
  end

  @impl true
  def list_checkpoints(remote_name) when is_binary(remote_name) do
    with {:ok, remote_workspace} <- Client.workspace(remote_name),
         {:ok, checkpoints} <- Sprites.list_checkpoints(remote_workspace) do
      {:ok, Enum.map(checkpoints, &checkpoint_to_map/1)}
    end
  end

  @impl true
  def create_checkpoint(remote_name, opts) when is_binary(remote_name) and is_list(opts) do
    with {:ok, remote_workspace} <- Client.workspace(remote_name),
         {:ok, messages} <- Sprites.create_checkpoint(remote_workspace, opts) do
      {:ok, Enum.map(messages, &stream_message_to_map/1)}
    end
  end

  @impl true
  def restore_checkpoint(remote_name, checkpoint_id)
      when is_binary(remote_name) and is_binary(checkpoint_id) do
    with {:ok, remote_workspace} <- Client.workspace(remote_name),
         {:ok, messages} <- Sprites.restore_checkpoint(remote_workspace, checkpoint_id) do
      {:ok, Enum.map(messages, &stream_message_to_map/1)}
    end
  end

  defp checkpoint_to_map(checkpoint) do
    %{
      id: Map.get(checkpoint, :id),
      comment: Map.get(checkpoint, :comment),
      create_time: Map.get(checkpoint, :create_time),
      history: Map.get(checkpoint, :history, [])
    }
  end

  defp stream_message_to_map(message) do
    %{
      type: Map.get(message, :type),
      data: Map.get(message, :data),
      error: Map.get(message, :error)
    }
  end
end
