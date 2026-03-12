defmodule Fizz.Workspaces.Provider do
  @moduledoc """
  Behaviour for remote workspace runtime providers.
  """

  alias Fizz.Workspaces.ConsoleSession

  @type response :: {:ok, map()} | {:ok, list()} | {:error, term()}

  @callback provider_id() :: String.t()
  @callback exec_timeout_ms_default() :: pos_integer()
  @callback log_retention_days() :: pos_integer()
  @callback checkpoint_retention_days() :: pos_integer()
  @callback service_log_tail_lines() :: pos_integer()

  @callback create_workspace(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback delete_workspace(String.t()) :: :ok | {:error, term()}
  @callback update_url_auth(String.t(), :default | :public | :bearer) :: :ok | {:error, term()}
  @callback apply_network_policy(String.t(), [String.t()]) :: :ok | {:error, term()}

  @callback start_exec(String.t(), String.t(), [String.t()], keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback kill_exec_session(String.t(), String.t()) :: response()

  @callback start_console_runner(ConsoleSession.t(), pid(), [{String.t(), String.t()}]) ::
              GenServer.on_start()
  @callback setup_git_credentials(String.t(), String.t(), keyword()) ::
              {:ok, [{String.t(), String.t()}]} | {:error, term()}

  @callback list_services(String.t()) :: response()
  @callback get_service(String.t(), String.t()) :: response()
  @callback put_service(String.t(), String.t(), map()) :: response()
  @callback start_service(String.t(), String.t()) :: response()
  @callback stop_service(String.t(), String.t()) :: response()
  @callback service_logs(String.t(), String.t(), keyword()) :: response()

  @callback list_checkpoints(String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback create_checkpoint(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback restore_checkpoint(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
end
