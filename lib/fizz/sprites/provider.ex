defmodule Fizz.Sprites.Provider do
  @moduledoc """
  Behaviour for Sprite provider integrations.
  """

  @type command_handle :: term()
  @type checkpoint_message :: map()
  @type checkpoint :: map()
  @type session :: map()
  @type policy :: map()

  @callback configured?() :: boolean()

  @callback create_sprite(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback destroy_sprite(String.t()) :: :ok | {:error, term()}
  @callback get_sprite(String.t()) :: {:ok, map()} | {:error, term()}

  @callback run_command(String.t(), String.t(), [String.t()], keyword()) ::
              {:ok, %{output: binary(), exit_code: non_neg_integer()}} | {:error, term()}

  @callback start_console(String.t(), String.t(), [String.t()], keyword()) ::
              {:ok, command_handle()} | {:error, term()}

  @callback attach_console(String.t(), String.t(), keyword()) ::
              {:ok, command_handle()} | {:error, term()}

  @callback write_console(command_handle(), iodata()) :: :ok | {:error, term()}
  @callback resize_console(command_handle(), pos_integer(), pos_integer()) ::
              :ok | {:error, term()}
  @callback close_console(command_handle()) :: :ok | {:error, term()}
  @callback await_console(command_handle(), timeout()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @callback list_sessions(String.t()) :: {:ok, [session()]} | {:error, term()}
  @callback kill_session(String.t(), String.t()) :: :ok | {:error, term()}

  @callback list_checkpoints(String.t()) :: {:ok, [checkpoint()]} | {:error, term()}
  @callback get_checkpoint(String.t(), String.t()) :: {:ok, checkpoint()} | {:error, term()}

  @callback create_checkpoint(String.t(), keyword()) ::
              {:ok, [checkpoint_message()]} | {:error, term()}

  @callback restore_checkpoint(String.t(), String.t()) ::
              {:ok, [checkpoint_message()]} | {:error, term()}

  @callback get_network_policy(String.t()) :: {:ok, policy()} | {:error, term()}
  @callback update_network_policy(String.t(), policy()) :: :ok | {:error, term()}

  @callback get_url_settings(String.t()) :: {:ok, map()} | {:error, term()}
  @callback update_url_settings(String.t(), map()) :: :ok | {:error, term()}
end
